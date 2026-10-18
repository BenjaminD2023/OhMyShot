"""Draws the layout corpus: screen-sized pages with formulas among text, as the formula pack's layout model meets them.

    python3 Tools/model-packs/layout_pages.py OUT

Four pages drawn by Google Chrome with KaTeX at 2x (820 × 560 points: a web page, a chat answer in dark mode, a page
in Chinese, notes with formulas on lines of their own and one on a dark slide) and a paper's page drawn by xelatex at
192 dpi. `formula_pack.py check-layout` reads them with the real screenshots of Tools/ocr-bench/real, which hold no
formulas. Needs Google Chrome (KaTeX comes from jsDelivr), xelatex, and pdftoppm.
"""
import os
import subprocess
import sys

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
KATEX = "https://cdn.jsdelivr.net/npm/katex@0.16.22/dist"

HEAD = f"""<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="{KATEX}/katex.min.css">
<script defer src="{KATEX}/katex.min.js"></script>
<script defer src="{KATEX}/contrib/auto-render.min.js" onload="renderMathInElement(document.body, {{delimiters: [{{left: '$$', right: '$$', display: true}}, {{left: '$', right: '$', display: false}}]}})"></script>
<style>body {{ margin: 32px 40px; font: 16px/1.6 -apple-system, 'PingFang SC', sans-serif; }} STYLE</style></head><body>"""

PAGES = {
    "web-light": ("", r"""
<h2>Gradient descent</h2>
<p>Given a loss $L(\theta)$, each step moves the parameters against the gradient, $\theta_{t+1} = \theta_t - \eta \nabla L(\theta_t)$,
where $\eta > 0$ is the learning rate. For a quadratic $L(x) = \frac{1}{2} x^\top A x$ the iteration converges when $\eta < 2 / \lambda_{\max}(A)$.</p>
<p>The mean squared error over $n$ samples is</p>
$$\mathrm{MSE} = \frac{1}{n} \sum_{i=1}^{n} (y_i - \hat{y}_i)^2$$
<p>and its gradient with respect to the prediction $\hat{y}_i$ is $-\frac{2}{n}(y_i - \hat{y}_i)$. Version 2.0 of the library ships on May 3, 2026.</p>
"""),
    "chat-dark": ("body { background: #212121; color: #ececec; }", r"""
<p>The quadratic formula gives both roots of $ax^2 + bx + c = 0$:</p>
$$x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$$
<p>When the discriminant $\Delta = b^2 - 4ac$ is negative, the roots are complex: $x = -\frac{b}{2a} \pm i\frac{\sqrt{-\Delta}}{2a}$.</p>
<p>For example, $x^2 + 1 = 0$ has roots $\pm i$. That's all you need for the exercise on page 12.</p>
"""),
    "zh-light": ("", r"""
<h3>勾股定理</h3>
<p>直角三角形两条直角边分别为 $a$、$b$，斜边为 $c$，则有 $a^2 + b^2 = c^2$。由此可得斜边长度 $c = \sqrt{a^2 + b^2}$。</p>
<p>欧拉公式把指数函数和三角函数联系起来：</p>
$$e^{i\theta} = \cos\theta + i\sin\theta$$
<p>取 $\theta = \pi$ 时得到 $e^{i\pi} + 1 = 0$，被称为最美的数学公式。本文更新于 2026 年 10 月。</p>
"""),
    "notes": (".slide { background: #1f1f1f; color: #eee; margin: 0 -40px; padding: 8px 40px; }", r"""
<h2>Notes on two formulas</h2>
<p>The first one sets the scale of everything that follows:</p>
$$x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$$
<p>and the second is read the same way, a line below it:</p>
$$\text{速度} = \frac{\text{路程}}{\text{时间}}$$
<div class="slide"><p>On a dark slide it reads too:</p>
$$\mathrm{Attention}(Q, K, V) = \mathrm{softmax}\left(\frac{QK^T}{\sqrt{d_k}}\right) V$$</div>
"""),
}

PAPER = r"""\documentclass[11pt]{article}
\usepackage[paperwidth=6.2in,paperheight=4.4in,margin=0.35in]{geometry}
\usepackage{amsmath,amssymb}
\pagestyle{empty}
\begin{document}
\section*{2\quad Method}
Let $x \in \mathbb{R}^d$ be an input and $f_\theta(x)$ the network's output. We minimize the
regularized objective, where $\lambda \geq 0$ trades the data term against the norm of the weights:
\begin{equation}
  \mathcal{L}(\theta) = \frac{1}{N} \sum_{i=1}^{N} \ell\bigl(f_\theta(x_i), y_i\bigr) + \lambda \lVert \theta \rVert_2^2 .
\end{equation}
The attention weights are $\alpha_{ij} = \exp(e_{ij}) / \sum_k \exp(e_{ik})$, so that
$\sum_j \alpha_{ij} = 1$ for every query $i$. In all experiments we set $d = 512$ and train for 40 epochs.
\end{document}
"""


def main(out):
    out = os.path.abspath(out)
    os.makedirs(out, exist_ok=True)
    for name, (style, body) in PAGES.items():
        html = os.path.join(out, f"{name}.html")
        with open(html, "w", encoding="utf-8") as f:
            f.write(HEAD.replace("STYLE", style) + body + "</body></html>")
        png = os.path.join(out, f"{name}.png")
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2",
                        "--window-size=820,560", "--virtual-time-budget=8000", f"--screenshot={png}", f"file://{html}"],
                       check=True, capture_output=True)
        os.remove(html)
        print(png)
    with open(os.path.join(out, "paper.tex"), "w", encoding="utf-8") as f:
        f.write(PAPER)
    subprocess.run(["xelatex", "-interaction=batchmode", "paper.tex"], cwd=out, check=True, capture_output=True)
    subprocess.run(["pdftoppm", "-r", "192", "-png", "-singlefile", "paper.pdf", "paper"], cwd=out, check=True)
    for extension in ("tex", "pdf", "aux", "log"):
        os.remove(os.path.join(out, f"paper.{extension}"))
    print(os.path.join(out, "paper.png"))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
