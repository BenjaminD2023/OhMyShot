"""Draw a few screen-style tables with headless Chrome, at 1x and 2x, with their rows as JSON truth; and add
ocr-bench's two tables (from `ocr-bench --save`) under the same names.

tables.py OUT_DIR BENCH_DIR
"""
import html, json, shutil, subprocess, sys
from pathlib import Path
out, bench = Path(sys.argv[1]).absolute(), Path(sys.argv[2])
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TABLES = {
 "t-pricing-zh": (False, [["套餐", "月付", "年付", "存储空间", "设备数"],
                          ["免费版", "¥0", "¥0", "5 GB", "1"],
                          ["个人版", "¥18", "¥168", "200 GB", "3"],
                          ["家庭版", "¥38", "¥358", "2 TB", "6"],
                          ["企业版", "联系销售", "联系销售", "不限", "不限"]]),
 "t-specs-en": (False, [["Model", "Chip", "Memory", "Storage", "Weight", "Price"],
                        ["Air 13\"", "M4", "16 GB", "256 GB", "1.24 kg", "$999"],
                        ["Air 15\"", "M4", "16 GB", "512 GB", "1.51 kg", "$1,399"],
                        ["Pro 14\"", "M4 Pro", "24 GB", "512 GB", "1.60 kg", "$1,999"],
                        ["Pro 16\"", "M4 Max", "48 GB", "1 TB", "2.14 kg", "$3,999"]]),
 "t-dark-metrics": (True, [["Endpoint", "p50", "p95", "Errors", "RPS"],
                           ["/api/login", "38 ms", "112 ms", "0.02%", "1,204"],
                           ["/api/search", "84 ms", "391 ms", "0.31%", "3,877"],
                           ["/api/upload", "412 ms", "1.9 s", "1.07%", "96"],
                           ["/api/feed", "57 ms", "203 ms", "0.00%", "8,450"],
                           ["/healthz", "1 ms", "3 ms", "0.00%", "120"]]),
 "t-schedule-zh": (False, [["时间", "周一", "周二", "周三", "周四", "周五"],
                           ["08:00", "数学", "语文", "英语", "物理", "化学"],
                           ["09:00", "语文", "数学", "生物", "英语", "历史"],
                           ["10:30", "体育", "地理", "数学", "政治", "语文"],
                           ["14:00", "自习", "美术", "音乐", "数学", "班会"]]),
}
for tid, (dark, rows) in TABLES.items():
    fg, bg, line, head = ("#e6e6e6", "#1e1e1e", "#3a3a3a", "#2a2a2a") if dark else ("#1d1d1f", "#ffffff", "#d2d2d7", "#f5f5f7")
    body = "".join("<tr>" + "".join((f"<th>{html.escape(c)}</th>" if i == 0 else f"<td>{html.escape(c)}</td>") for c in r) + "</tr>" for i, r in enumerate(rows))
    page = f"""<!doctype html><meta charset=utf-8><style>
    body{{margin:0;background:{bg};color:{fg};font:13px -apple-system,'PingFang SC',sans-serif}}
    table{{border-collapse:collapse;margin:12px}} th,td{{border:1px solid {line};padding:5px 10px;text-align:left}}
    th{{background:{head};font-weight:600}}</style><table>{body}</table>"""
    (out / f"{tid}.html").write_text(page)
    for scale in (1, 2):
        subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", f"--force-device-scale-factor={scale}",
                        "--window-size=720,260", f"--screenshot={out / f'{tid}_{scale}x.png'}", (out / f"{tid}.html").as_uri()],
                       capture_output=True, timeout=60)
        subprocess.run(["magick", str(out / f"{tid}_{scale}x.png"), "-trim", "-bordercolor", bg, "-border", str(10 * scale), "+repage", str(out / f"{tid}_{scale}x.png")], check=True)
    (out / f"{tid}.json").write_text(json.dumps(rows, ensure_ascii=False))
# ocr-bench's tables (Tools/ocr-bench, Corpus.swift).
BENCH = {
    "zh": [["名称", "数量", "单价"], ["苹果", "3", "¥12.50"], ["Banana", "12", "¥8.00"], ["牛奶", "2", "¥15.90"], ["合计", "17", "¥165.30"]],
    "en": [["Region", "Q1", "Q2", "Change"], ["North", "1,240", "1,385", "+11.7%"], ["South", "980", "912", "-6.9%"], ["West", "1,105", "1,230", "+11.3%"]],
}
for lang, rows in BENCH.items():
    shutil.copyfile(bench / f"table-{lang}.png", out / f"t-bench-{lang}_bench.png")
    (out / f"t-bench-{lang}.json").write_text(json.dumps(rows, ensure_ascii=False))
print("ok")
