"""
PostGIS LLM 最小验证脚手架。

支持两种模式：
  - API 模式（默认）：调 Anthropic API 让远端 LLM 生成 SQL，需要 ANTHROPIC_API_KEY
  - BYOSQL 模式：从本地 claude-sqls.yaml 读取 LLM 已生成的 SQL，零 API 成本
                 用法：python verify.py --byosql claude-sqls.yaml

流程：
  1. 读 questions.yaml（10 题 + golden_sql + 4 类陷阱标注）
  2. 拿到每题的 LLM SQL（API 调用或 BYOSQL 文件）
  3. 同时执行 LLM SQL 与 golden SQL，对比结果集
  4. 分类失败：syntax / runtime / wrong_result / 命中陷阱（A-D）
  5. 汇总成 results.md
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import psycopg
import yaml

ROOT = Path(__file__).parent
QUESTIONS_FILE = ROOT / "questions.yaml"
RESULTS_FILE = ROOT / "results.md"

DB_DSN = os.environ.get(
    "POSTGIS_DSN",
    "host=localhost port=55632 dbname=gis_demo user=gis password=gis connect_timeout=5 sslmode=disable",
)
MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-opus-4-7")

SCHEMA_PROMPT = """\
你是一个 PostGIS 助手。下面是数据库 schema（含字段说明）。基于用户问题生成**单条**可执行的 SQL。
只返回 SQL，不加任何解释、不加 markdown 代码块。

== Schema ==
districts(id, name TEXT, geom POLYGON SRID 4326)
  -- 行政区表，name 取值如 '东城区' / '西城区' / '海淀区' / '朝阳区'

parks(id, name TEXT, district_id INT FK->districts.id, geom POLYGON SRID 4326)

subway_stations(id, name TEXT, geom POINT SRID 4326)

schools(id, name TEXT, type TEXT, district_id INT, geom POINT SRID 4326)
  -- type 取值如 '小学' / '中学' / '大学'

roads(id, name TEXT, type TEXT, length_m DOUBLE PRECISION, geom LINESTRING SRID 4326)
  -- length_m 是预计算字段（米）；type 如 '高速' / '主干道' / '次干道'

hospitals(id, name TEXT, level TEXT, district_id INT, geom POINT SRID 4326)
  -- level 如 '三甲' / '二级' / '社区'

residential(id, name TEXT, district_id INT, geom POLYGON SRID 4326)

所有 geom 字段已建 GiST 索引。
"""


@dataclass
class CaseResult:
    qid: str
    level: str
    nl: str
    traps: list[str]
    llm_sql: str = ""
    llm_error: str | None = None
    llm_rows: list[Any] = field(default_factory=list)
    golden_rows: list[Any] = field(default_factory=list)
    match: bool = False
    failure_class: str | None = None     # syntax / runtime / wrong_result / pass
    trap_hits: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


def call_llm_api(client, nl: str) -> str:
    msg = client.messages.create(
        model=MODEL,
        max_tokens=512,
        system=SCHEMA_PROMPT,
        messages=[{"role": "user", "content": nl}],
    )
    text = "".join(b.text for b in msg.content if hasattr(b, "text"))
    text = text.strip()
    text = re.sub(r"^```(?:sql)?\s*|\s*```$", "", text, flags=re.IGNORECASE | re.MULTILINE)
    return text.strip().rstrip(";") + ";"


def load_byosql(path: Path) -> dict[str, str]:
    raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    return {item["id"]: item["sql"].strip().rstrip(";") + ";" for item in raw["sqls"]}


def execute(conn: psycopg.Connection, sql: str) -> list[Any]:
    with conn.cursor() as cur:
        cur.execute(sql)
        rows = cur.fetchall()
    return [tuple(r) for r in rows]


def normalize_rows(rows: list[Any]) -> set[tuple]:
    """把行集转成可比较的集合——值四舍五入到 6 位，列顺序敏感"""
    out = set()
    for r in rows:
        norm = tuple(round(v, 6) if isinstance(v, float) else v for v in r)
        out.add(norm)
    return out


def compare_results(llm_rows: list[Any], golden_rows: list[Any]) -> tuple[bool, str]:
    """LLM 比 golden 多带列也算 pass（noise），但语义不一致则 wrong。

    返回 (是否通过, 备注)。
    """
    llm_set = normalize_rows(llm_rows)
    golden_set = normalize_rows(golden_rows)

    if llm_set == golden_set:
        return True, ""

    # 长度不一致先排除
    if len(llm_rows) == 0 or len(golden_rows) == 0:
        if llm_set == golden_set:
            return True, ""
        return False, ""

    n_llm = len(llm_rows[0])
    n_gold = len(golden_rows[0])
    if n_llm <= n_gold:
        return False, ""

    # LLM 多带列——尝试按"取末尾 n_gold 列"或"取首 n_gold 列"投影
    for slicer, label in (
        (lambda r: r[-n_gold:], "last"),
        (lambda r: r[:n_gold], "first"),
    ):
        proj = normalize_rows([slicer(r) for r in llm_rows])
        if proj == golden_set:
            return True, f"LLM 多 {n_llm - n_gold} 列；按 {label}-{n_gold} 投影后与 golden 一致"

    return False, ""


# 启发式陷阱检测——纯静态分析，发现一个就标记
TRAP_PATTERNS = {
    "A_no_index": [
        (r"\bST_Distance\s*\([^)]+\)\s*<", "用 ST_Distance < N，不走 GiST 索引"),
    ],
    "A_no_geography": [
        (r"\bST_Distance\s*\(\s*geom\b(?![^)]*::geography)", "ST_Distance 不转 geography，单位是度数"),
        (r"\bST_Length\s*\(\s*geom\s*\)(?!.*geography)", "ST_Length 不转 geography，单位是度数"),
        (r"\bST_Area\s*\(\s*geom\s*\)(?!.*geography)", "ST_Area 不转 geography，单位是度²"),
    ],
    "B_wrong_relation": [
        (r"\bST_Crosses\b.*polygon", "ST_Crosses 对 Polygon-Polygon 不适用"),
    ],
    "D_cartesian": [
        (r"LEFT JOIN.*LEFT JOIN.*LEFT JOIN.*\bCOUNT\s*\((?!DISTINCT)", "三表 LEFT JOIN + COUNT 笛卡尔积"),
    ],
}


def detect_traps(sql: str) -> list[str]:
    hits = []
    sql_low = sql.lower()
    for trap, patterns in TRAP_PATTERNS.items():
        for pat, desc in patterns:
            if re.search(pat, sql_low):
                hits.append(f"{trap}: {desc}")
                break
    return hits


def run_one(sql_provider, conn: psycopg.Connection, q: dict) -> CaseResult:
    case = CaseResult(qid=q["id"], level=q["level"], nl=q["nl"], traps=q.get("traps", []))

    try:
        case.llm_sql = sql_provider(q)
    except Exception as e:
        case.llm_error = f"SQL provider failed: {e}"
        case.failure_class = "llm_error"
        return case

    case.trap_hits = detect_traps(case.llm_sql)

    # Q18 专项：题目要求用 ST_Relate 写 DE-9IM 矩阵，直接用 ST_Within 逻辑正确但跳过了考点
    if case.qid == "Q18" and not re.search(r"\bST_Relate\b", case.llm_sql, re.IGNORECASE):
        case.trap_hits.append("B_no_st_relate: 未用 ST_Relate，直接替换为等价函数（跳过 DE-9IM 考点）")

    # golden 必须能跑——跑不通说明 schema/数据出问题
    try:
        case.golden_rows = execute(conn, q["golden_sql"])
    except Exception as e:
        conn.rollback()
        case.notes.append(f"⚠️  GOLDEN SQL 执行失败：{e}")
        return case

    # LLM SQL 执行
    try:
        case.llm_rows = execute(conn, case.llm_sql)
    except psycopg.errors.SyntaxError as e:
        conn.rollback()
        case.llm_error = str(e).splitlines()[0]
        case.failure_class = "syntax"
        return case
    except Exception as e:
        conn.rollback()
        case.llm_error = str(e).splitlines()[0]
        case.failure_class = "runtime"
        return case

    # 结果对比（容忍 LLM 多带列的情况）
    matched, note = compare_results(case.llm_rows, case.golden_rows)
    if note:
        case.notes.append(note)
    if matched:
        case.match = True
        case.failure_class = "pass" if not case.trap_hits else "pass_with_smell"
    else:
        case.failure_class = "wrong_result"

    return case


def write_report(cases: list[CaseResult]) -> None:
    lines = ["# PostGIS LLM 验证结果", ""]
    lines.append(f"模型：`{MODEL}`  ｜  样本：{len(cases)} 题")
    lines.append("")

    summary = {"pass": 0, "pass_with_smell": 0, "syntax": 0, "runtime": 0, "wrong_result": 0, "llm_error": 0}
    for c in cases:
        summary[c.failure_class or "unknown"] = summary.get(c.failure_class or "unknown", 0) + 1

    lines.append("## 总体")
    lines.append("")
    lines.append("| 结果 | 数量 |")
    lines.append("|------|------|")
    for k in ["pass", "pass_with_smell", "wrong_result", "syntax", "runtime", "llm_error"]:
        lines.append(f"| {k} | {summary.get(k, 0)} |")
    lines.append("")

    lines.append("## 逐题")
    for c in cases:
        lines.append(f"\n### {c.qid} [{c.level}] — {c.nl}")
        lines.append(f"- 结果：**{c.failure_class}**" + (" ✅" if c.match else " ❌"))
        if c.trap_hits:
            lines.append("- 陷阱命中：")
            for t in c.trap_hits:
                lines.append(f"  - {t}")
        lines.append("\n```sql")
        lines.append(c.llm_sql.strip())
        lines.append("```")
        if c.llm_error:
            lines.append(f"\n错误：`{c.llm_error}`")
        if not c.match and not c.llm_error:
            lines.append(
                f"\n结果不匹配——LLM 返回 {len(c.llm_rows)} 行 / golden 返回 {len(c.golden_rows)} 行"
            )
        for n in c.notes:
            lines.append(f"\n> {n}")

    RESULTS_FILE.write_text("\n".join(lines), encoding="utf-8")
    print(f"\n报告已写入：{RESULTS_FILE}")


def build_sql_provider(args):
    if args.byosql:
        path = Path(args.byosql)
        sql_map = load_byosql(path)
        print(f"BYOSQL 模式：从 {path.name} 读取 {len(sql_map)} 条 SQL\n")

        def provider(q):
            if q["id"] not in sql_map:
                raise KeyError(f"{q['id']} 在 {path.name} 中缺失")
            return sql_map[q["id"]]

        return provider, f"byosql:{path.name}"

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("ERROR: 未设置 ANTHROPIC_API_KEY；如不打算调 API，请用 --byosql claude-sqls.yaml", file=sys.stderr)
        sys.exit(1)

    from anthropic import Anthropic

    client = Anthropic()
    print(f"API 模式：模型 {MODEL}\n")

    def provider(q):
        time.sleep(0.5)
        return call_llm_api(client, q["nl"])

    return provider, MODEL


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--byosql", help="读取本地 LLM-SQL 文件（YAML，含 sqls: [{id, sql}]）")
    parser.add_argument("--questions", default="questions.yaml", help="问题文件（默认 questions.yaml）")
    args = parser.parse_args()

    questions = yaml.safe_load((ROOT / args.questions).read_text(encoding="utf-8"))["questions"]
    sql_provider, model_label = build_sql_provider(args)

    global MODEL
    MODEL = model_label

    with psycopg.connect(DB_DSN) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM districts")
            (n,) = cur.fetchone()
        if n != 4:
            print(f"WARN: districts 行数={n}，期望 4。init.sql 是否生效？", file=sys.stderr)

        cases = []
        for q in questions:
            print(f"→ {q['id']} [{q['level']}] {q['nl']}")
            c = run_one(sql_provider, conn, q)
            cases.append(c)
            mark = "✅" if c.match else "❌"
            extra = f"  陷阱：{','.join(c.trap_hits)}" if c.trap_hits else ""
            print(f"   {mark} {c.failure_class}{extra}")

    write_report(cases)


if __name__ == "__main__":
    main()
