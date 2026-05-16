# PostGIS + LLM 最小验证

一个用来评测 LLM 写 PostGIS SQL 能力的最小可复现框架。给 LLM 一份数据库 schema，让它把自然语言转成 SQL，本地跑通后与 golden SQL 对比结果集，并对 4 类常见陷阱做静态扫描。

## 验证设计

18 道题（Q1-Q10 基础 + Q11-Q18 刁钻题），刻意覆盖 4 个真坑：

| 坑 | 含义 | 命中题 |
|----|------|--------|
| **A** | 空间索引利用（DWithin vs Distance、是否转 geography） | Q2 / Q4 / Q5 / Q7 / Q12 / Q14 / Q15 / Q17 |
| **B** | 复杂空间关系（Crosses / Overlaps / Touches / Relate） | Q6 / Q9 / Q11 / Q13 / Q15 / Q16 / Q18 |
| **C** | 业务语义→表/字段映射（"海淀"在哪、"小学"是表还是字段值） | Q1 / Q3 |
| **D** | 大数据量爆炸（笛卡尔积、无 LIMIT） | Q7 / Q8 / Q10 / Q16 / Q17 |

数据集：4 个行政区 + 8 公园 + 10 地铁站 + 15 学校 + 12 道路 + 6 医院 + 12 住宅区，全部基于近似北京坐标手工编排，**有意构造若干越界/边界情况**（跨界示例公园、长安街跨多区、离天安门 1km 边界附近的地铁站等）让陷阱可以触发。

## 两种运行模式

### 模式 1：BYOSQL（推荐——零 API 成本）

把任意 LLM 生成好的 SQL 填入 [claude-sqls.yaml](claude-sqls.yaml)（仓库里附了一份示例），本地只跑执行+对比：

```bash
# 1. 启 PostGIS（首次拉镜像 ~300MB，端口 55432）
docker compose up -d
docker compose ps           # 等到 healthy

# 2. 装 Python 依赖（不含 anthropic 也能跑）
pip install psycopg[binary] PyYAML

# 3. 跑验证
python verify.py --byosql claude-sqls.yaml
```

### 模式 2：直连 API（需要 ANTHROPIC_API_KEY）

适合做模型对照（Haiku/Sonnet/Opus）：

```bash
pip install -r requirements.txt
export ANTHROPIC_API_KEY=sk-ant-...

# 默认 Opus 4.7
python verify.py

# 切模型
ANTHROPIC_MODEL=claude-haiku-4-5-20251001 python verify.py
mv results.md results-haiku.md

ANTHROPIC_MODEL=claude-sonnet-4-6 python verify.py
mv results.md results-sonnet.md
```

18 题成本 Opus < $0.20、Haiku 几乎免费。

跑完看 `results.md`：总体计数、每题 LLM 原始 SQL、陷阱命中详情、错误信息。

## 清理

```bash
docker compose down -v      # -v 连数据卷一起删
```

## 扩展

- 增加题目：在 [questions.yaml](questions.yaml) 追加，按 `{id, level, nl, traps, golden_sql, eval_notes}` 结构写
- 扩展陷阱检测：编辑 [verify.py](verify.py) 里的 `TRAP_PATTERNS`，加正则即可
- 换数据集：改 [init.sql](init.sql) 重建表，并相应更新 schema prompt 和 golden SQL

## License

Apache 2.0 — 详见 [LICENSE](LICENSE)。
