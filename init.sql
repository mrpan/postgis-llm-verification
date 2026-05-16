-- PostGIS LLM 验证用最小数据集
-- 4 个行政区 + 8 公园 + 10 地铁站 + 15 学校 + 12 道路 + 6 医院
-- 坐标用近似北京经纬度（SRID 4326），geom 字段建 GiST 索引以测试 LLM 是否会用 ST_DWithin

CREATE EXTENSION IF NOT EXISTS postgis;

-- ===== 表结构 =====
DROP TABLE IF EXISTS roads, schools, parks, hospitals, residential, subway_stations, districts CASCADE;

CREATE TABLE districts (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  geom geometry(Polygon, 4326) NOT NULL
);

CREATE TABLE parks (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  district_id INT REFERENCES districts(id),
  geom geometry(Polygon, 4326) NOT NULL
);

CREATE TABLE subway_stations (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  geom geometry(Point, 4326) NOT NULL
);

CREATE TABLE schools (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL,         -- '小学' / '中学' / '大学'
  district_id INT REFERENCES districts(id),
  geom geometry(Point, 4326) NOT NULL
);

CREATE TABLE roads (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL,         -- '高速' / '主干道' / '次干道'
  length_m DOUBLE PRECISION,
  geom geometry(LineString, 4326) NOT NULL
);

CREATE TABLE hospitals (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  level TEXT NOT NULL,        -- '三甲' / '二级' / '社区'
  district_id INT REFERENCES districts(id),
  geom geometry(Point, 4326) NOT NULL
);

CREATE TABLE residential (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  district_id INT REFERENCES districts(id),
  geom geometry(Polygon, 4326) NOT NULL
);

CREATE INDEX idx_parks_geom ON parks USING GIST(geom);
CREATE INDEX idx_subway_geom ON subway_stations USING GIST(geom);
CREATE INDEX idx_schools_geom ON schools USING GIST(geom);
CREATE INDEX idx_roads_geom ON roads USING GIST(geom);
CREATE INDEX idx_hospitals_geom ON hospitals USING GIST(geom);
CREATE INDEX idx_districts_geom ON districts USING GIST(geom);

-- ===== 种子数据 =====
-- 4 个行政区（用矩形近似，覆盖北京中心区域 116.30~116.50, 39.85~40.00）

INSERT INTO districts (name, geom) VALUES
  ('东城区', ST_GeomFromText('POLYGON((116.40 39.88, 116.44 39.88, 116.44 39.95, 116.40 39.95, 116.40 39.88))', 4326)),
  ('西城区', ST_GeomFromText('POLYGON((116.34 39.88, 116.40 39.88, 116.40 39.95, 116.34 39.95, 116.34 39.88))', 4326)),
  ('海淀区', ST_GeomFromText('POLYGON((116.28 39.92, 116.34 39.92, 116.34 40.02, 116.28 40.02, 116.28 39.92))', 4326)),
  ('朝阳区', ST_GeomFromText('POLYGON((116.44 39.85, 116.55 39.85, 116.55 39.98, 116.44 39.98, 116.44 39.85))', 4326));

-- 8 个公园
INSERT INTO parks (name, district_id, geom) VALUES
  ('景山公园', 2, ST_GeomFromText('POLYGON((116.394 39.924, 116.398 39.924, 116.398 39.928, 116.394 39.928, 116.394 39.924))', 4326)),
  ('北海公园', 2, ST_GeomFromText('POLYGON((116.388 39.925, 116.394 39.925, 116.394 39.932, 116.388 39.932, 116.388 39.925))', 4326)),
  ('天坛公园', 1, ST_GeomFromText('POLYGON((116.405 39.880, 116.420 39.880, 116.420 39.895, 116.405 39.895, 116.405 39.880))', 4326)),
  ('颐和园', 3, ST_GeomFromText('POLYGON((116.282 39.995, 116.298 39.995, 116.298 40.012, 116.282 40.012, 116.282 39.995))', 4326)),
  ('圆明园', 3, ST_GeomFromText('POLYGON((116.298 40.000, 116.314 40.000, 116.314 40.015, 116.298 40.015, 116.298 40.000))', 4326)),
  ('紫竹院公园', 3, ST_GeomFromText('POLYGON((116.310 39.940, 116.318 39.940, 116.318 39.948, 116.310 39.948, 116.310 39.940))', 4326)),
  ('朝阳公园', 4, ST_GeomFromText('POLYGON((116.470 39.940, 116.485 39.940, 116.485 39.955, 116.470 39.955, 116.470 39.940))', 4326)),
  -- Q9 跨界公园：横跨海淀和西城边界
  ('跨界示例公园', 3, ST_GeomFromText('POLYGON((116.336 39.945, 116.346 39.945, 116.346 39.952, 116.336 39.952, 116.336 39.945))', 4326));

-- 10 个地铁站（天安门附近密集，远处稀疏）
INSERT INTO subway_stations (name, geom) VALUES
  ('天安门东', ST_SetSRID(ST_MakePoint(116.401, 39.908), 4326)),    -- 距天安门 ~350m
  ('天安门西', ST_SetSRID(ST_MakePoint(116.394, 39.908), 4326)),    -- ~280m
  ('王府井', ST_SetSRID(ST_MakePoint(116.418, 39.910), 4326)),       -- ~1800m
  ('东单', ST_SetSRID(ST_MakePoint(116.418, 39.905), 4326)),         -- ~1900m
  ('前门', ST_SetSRID(ST_MakePoint(116.398, 39.899), 4326)),         -- ~1100m，刚刚超
  ('国家图书馆', ST_SetSRID(ST_MakePoint(116.319, 39.945), 4326)),
  -- Q13 专用：紫竹院站在紫竹院公园(116.310-116.318, 39.940-39.948)内部
  ('紫竹院站', ST_SetSRID(ST_MakePoint(116.314, 39.944), 4326)),
  ('海淀黄庄', ST_SetSRID(ST_MakePoint(116.317, 39.984), 4326)),
  ('西单', ST_SetSRID(ST_MakePoint(116.374, 39.908), 4326)),
  ('国贸', ST_SetSRID(ST_MakePoint(116.461, 39.910), 4326)),
  ('望京', ST_SetSRID(ST_MakePoint(116.476, 39.992), 4326));

-- 15 个学校
INSERT INTO schools (name, type, district_id, geom) VALUES
  ('史家小学', '小学', 1, ST_SetSRID(ST_MakePoint(116.418, 39.917), 4326)),
  ('北京二中', '中学', 1, ST_SetSRID(ST_MakePoint(116.420, 39.928), 4326)),
  ('府学小学', '小学', 1, ST_SetSRID(ST_MakePoint(116.412, 39.943), 4326)),
  ('实验二小', '小学', 2, ST_SetSRID(ST_MakePoint(116.371, 39.916), 4326)),
  ('北京四中', '中学', 2, ST_SetSRID(ST_MakePoint(116.378, 39.929), 4326)),
  ('清华附小', '小学', 3, ST_SetSRID(ST_MakePoint(116.330, 39.998), 4326)),
  ('人大附中', '中学', 3, ST_SetSRID(ST_MakePoint(116.308, 39.978), 4326)),
  ('北大附小', '小学', 3, ST_SetSRID(ST_MakePoint(116.305, 39.990), 4326)),
  ('清华大学', '大学', 3, ST_SetSRID(ST_MakePoint(116.326, 40.003), 4326)),
  ('北京大学', '大学', 3, ST_SetSRID(ST_MakePoint(116.310, 39.992), 4326)),
  ('北航附小', '小学', 3, ST_SetSRID(ST_MakePoint(116.330, 39.978), 4326)),
  ('朝阳实验小学', '小学', 4, ST_SetSRID(ST_MakePoint(116.460, 39.920), 4326)),
  ('陈经纶中学', '中学', 4, ST_SetSRID(ST_MakePoint(116.470, 39.930), 4326)),
  ('日坛中学', '中学', 4, ST_SetSRID(ST_MakePoint(116.450, 39.915), 4326)),
  ('朝阳外国语小学', '小学', 4, ST_SetSRID(ST_MakePoint(116.490, 39.960), 4326)),
  -- Q11 专用：恰好在东城区(西边界)/西城区(东边界) x=116.40 上，ST_Touches 可命中
  ('东西边界实验学校', '小学', NULL, ST_SetSRID(ST_MakePoint(116.40, 39.91), 4326));

-- 12 条道路（部分单区、部分跨区）
INSERT INTO roads (name, type, length_m, geom) VALUES
  -- 长安街——东西向横穿东城+西城+朝阳
  ('长安街', '主干道', 8500, ST_GeomFromText('LINESTRING(116.32 39.908, 116.50 39.908)', 4326)),
  -- 二环——闭合环线，简化为半环跨多区
  ('北二环', '高速', 6200, ST_GeomFromText('LINESTRING(116.34 39.948, 116.44 39.948)', 4326)),
  -- 三环
  ('北三环', '高速', 5800, ST_GeomFromText('LINESTRING(116.30 39.975, 116.50 39.975)', 4326)),
  -- 海淀区内
  ('中关村大街', '主干道', 3200, ST_GeomFromText('LINESTRING(116.315 39.940, 116.315 39.998)', 4326)),
  -- 西城区内
  ('西直门内大街', '次干道', 1800, ST_GeomFromText('LINESTRING(116.355 39.940, 116.385 39.940)', 4326)),
  -- 东城区内
  ('王府井大街', '次干道', 1200, ST_GeomFromText('LINESTRING(116.418 39.905, 116.418 39.920)', 4326)),
  -- 朝阳区内
  ('建国路', '主干道', 4500, ST_GeomFromText('LINESTRING(116.45 39.910, 116.52 39.910)', 4326)),
  ('朝阳北路', '主干道', 5200, ST_GeomFromText('LINESTRING(116.45 39.945, 116.53 39.945)', 4326)),
  -- 跨海淀+西城
  ('阜成路', '主干道', 4800, ST_GeomFromText('LINESTRING(116.30 39.935, 116.40 39.935)', 4326)),
  ('德胜门外大街', '次干道', 2200, ST_GeomFromText('LINESTRING(116.378 39.945, 116.378 39.975)', 4326)),
  ('八达岭高速', '高速', 12000, ST_GeomFromText('LINESTRING(116.30 40.00, 116.30 40.15)', 4326)),
  ('小街', '次干道', 800, ST_GeomFromText('LINESTRING(116.420 39.920, 116.428 39.920)', 4326));

-- 6 个医院
INSERT INTO hospitals (name, level, district_id, geom) VALUES
  ('协和医院', '三甲', 1, ST_SetSRID(ST_MakePoint(116.418, 39.913), 4326)),         -- 王府井附近
  ('北京医院', '三甲', 1, ST_SetSRID(ST_MakePoint(116.418, 39.908), 4326)),         -- 东单附近
  ('同仁医院', '三甲', 1, ST_SetSRID(ST_MakePoint(116.420, 39.905), 4326)),         -- 东单附近
  ('西城社区医院', '社区', 2, ST_SetSRID(ST_MakePoint(116.370, 39.920), 4326)),
  ('北医三院', '三甲', 3, ST_SetSRID(ST_MakePoint(116.350, 39.985), 4326)),
  ('朝阳医院', '三甲', 4, ST_SetSRID(ST_MakePoint(116.460, 39.918), 4326));         -- 国贸附近

-- 12 个住宅区
INSERT INTO residential (name, district_id, geom) VALUES
  ('东四小区', 1, ST_GeomFromText('POLYGON((116.415 39.925, 116.422 39.925, 116.422 39.932, 116.415 39.932, 116.415 39.925))', 4326)),
  ('北锣鼓巷小区', 1, ST_GeomFromText('POLYGON((116.402 39.940, 116.408 39.940, 116.408 39.946, 116.402 39.946, 116.402 39.940))', 4326)),
  ('西四小区', 2, ST_GeomFromText('POLYGON((116.370 39.926, 116.376 39.926, 116.376 39.932, 116.370 39.932, 116.370 39.926))', 4326)),
  ('月坛北街', 2, ST_GeomFromText('POLYGON((116.350 39.918, 116.358 39.918, 116.358 39.925, 116.350 39.925, 116.350 39.918))', 4326)),
  ('五道口小区', 3, ST_GeomFromText('POLYGON((116.330 39.990, 116.338 39.990, 116.338 39.998, 116.330 39.998, 116.330 39.990))', 4326)),
  ('万柳小区', 3, ST_GeomFromText('POLYGON((116.290 39.965, 116.300 39.965, 116.300 39.975, 116.290 39.975, 116.290 39.965))', 4326)),
  ('中关村小区', 3, ST_GeomFromText('POLYGON((116.310 39.978, 116.320 39.978, 116.320 39.988, 116.310 39.988, 116.310 39.978))', 4326)),
  ('知春里小区', 3, ST_GeomFromText('POLYGON((116.328 39.978, 116.336 39.978, 116.336 39.984, 116.328 39.984, 116.328 39.978))', 4326)),
  ('望京小区', 4, ST_GeomFromText('POLYGON((116.470 39.985, 116.482 39.985, 116.482 39.998, 116.470 39.998, 116.470 39.985))', 4326)),
  ('国贸西小区', 4, ST_GeomFromText('POLYGON((116.450 39.905, 116.458 39.905, 116.458 39.915, 116.450 39.915, 116.450 39.905))', 4326)),
  ('双井小区', 4, ST_GeomFromText('POLYGON((116.460 39.890, 116.468 39.890, 116.468 39.898, 116.460 39.898, 116.460 39.890))', 4326)),
  ('百子湾小区', 4, ST_GeomFromText('POLYGON((116.490 39.895, 116.500 39.895, 116.500 39.905, 116.490 39.905, 116.490 39.895))', 4326)),
  -- Q15 专用：在紫竹院公园内（触发 NOT EXISTS 排除）且距国家图书馆站 ~470m（触发 EXISTS）
  ('紫竹院公园内小区', 3, ST_GeomFromText('POLYGON((116.311 39.942, 116.316 39.942, 116.316 39.947, 116.311 39.947, 116.311 39.942))', 4326));

ANALYZE;
