-- 真实模型测试：加载、打分合理性、平均耗时（wall time 用 os.time 秒级 / 多次平均）
local so_dir, model, log_dir, threads = arg[1], arg[2], arg[3], tonumber(arg[4] or "4")
package.cpath = so_dir .. "/?.so;" .. package.cpath
local m = require("rime_llm")
m.log_dir = log_dir
m.model_path = model
m.n_threads = threads

local cases = {
  { "他在公司当", { "经理", "经历", "精力" }, "经理" },
  { "我最近没有太多", { "经理", "经历", "精力" }, "精力" },
  { "这段难忘的", { "经理", "经历", "精力" }, "经历" },
  { "他生病后住进了", { "医院", "议员", "意愿" }, "医院" },
  { "国会里的一位", { "医院", "议员", "意愿" }, "议员" },
  { "这是一起严重的", { "时间", "事件", "实践" }, "事件" },
  { "理论必须联系", { "时间", "事件", "实践" }, "实践" },
  { "老师给了我很多", { "知道", "指导", "之道" }, "指导" },
  { "他对这个方案提出了", { "意义", "异议", "一一" }, "异议" },
  { "数学课上老师讲了", { "公式", "共识", "公示" }, "公式" },
}

-- 等模型加载（score 首次调用触发懒加载，加载期间返回 nil）
local t0 = os.time()
while true do
  local s = m.score(cases[1][1], cases[1][2])
  if s then break end
  if os.time() - t0 > 60 then print("FAIL: model not ready in 60s"); os.exit(1) end
  os.execute("sleep 0.5")
end
print(string.format("model ready after ~%ds", os.time() - t0))

-- 合理性
local hit = 0
for _, c in ipairs(cases) do
  local s = m.score(c[1], c[2])
  local ok = s[1] == c[3]
  if ok then hit = hit + 1 end
  print(string.format("%s | %s -> ranked=%s (expect %s) %s", c[1], table.concat(c[2], "/"), table.concat(s, ">"), c[3], ok and "OK" or "MISS"))
end
print(string.format("top-1: %d/%d", hit, #cases))

-- 耗时：300 次（每次换上下文避免内部缓存）
local N = 300
local start = os.time()
local clock0 = os.clock()
for i = 1, N do
  local c = cases[(i % #cases) + 1]
  m.score(c[1], c[2])
end
local wall = os.time() - start
print(string.format("%d scores: wall ~%ds (~%.0f ms/each, ±%.0f), cpu %.1fs", N, wall, wall * 1000 / N, 1000 / N, os.clock() - clock0))
