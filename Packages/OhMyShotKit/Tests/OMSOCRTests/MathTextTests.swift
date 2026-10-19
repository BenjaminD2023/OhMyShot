import Foundation
import Testing
@testable import OMSOCR

/// Formulas drawn readable where a translation is laid over the picture: each expectation is what the formula pack
/// wrote for the drawn pages (Resources/Formulas) or what LaTeX commonly holds.
struct MathTextTests {
    @Test func greekLettersOperatorsAndScriptsBecomeTheirCharacters() {
        #expect(MathText.readable("E = mc^{2}") == "E=mc²")
        #expect(MathText.readable(#"\theta_{t+1}=\theta_{t}-\eta\nabla L(\theta_{t})"#) == "θₜ₊₁=θₜ−η∇L(θₜ)")
        #expect(MathText.readable(#"\eta<2/\lambda_{\mathrm{m a x}}(A)"#) == "η<2/λₘₐₓ(A)")
        #expect(MathText.readable(#"\hat{y}_{i}"#) == "y\u{302}ᵢ")
        #expect(MathText.readable(#"x\in A"#) == "x∈A")
        #expect(MathText.readable(#"\text{rank}(A)\leq n"#) == "rank(A)≤n")
        #expect(MathText.readable(#"\mathbb{R}^{n}"#) == "ℝⁿ")
        #expect(MathText.readable(#"\mathcal{L}=\sum_{k}a_{k}"#) == "ℒ=∑ₖaₖ")
        #expect(MathText.readable(#"\operatorname{softmax}(QK^{T}/\sqrt{d_{k}})V"#) == "softmax(QKᵀ/√dₖ)V")
        #expect(MathText.readable(#"a\,b\,"#) == "a\u{2009}b")
    }

    @Test func aScriptWithoutUnicodesCharactersIsWrittenOut() {
        #expect(MathText.readable("x_{b}") == "x_b")
        #expect(MathText.readable("x^{2q}") == "x^(2q)")
        #expect(MathText.readable(#"\lim_{n\to\infty}x_{n}"#) == "lim_(n→∞) xₙ")
        #expect(MathText.readable(#"\sin x+\max_{i}y"#) == "sin x+maxᵢ y")
    }

    @Test func fractionsAndRootsTakeBracketsWhereTheyNeedThem() {
        #expect(MathText.readable(#"f(x)=\frac{1}{1+e^{-x}}"#) == "f(x)=1/(1+e⁻ˣ)")
        #expect(MathText.readable(#"L(x)=\frac{1}{2}x^{\top}Ax"#) == "L(x)=½xᵀAx")
        #expect(MathText.readable(#"\mathrm{M S E}=\frac{1}{n}\sum_{i=1}^{n}(y_{i}-\hat{y}_{i})^{2}"#) == "MSE=(1/n)∑ᵢ₌₁ⁿ(yᵢ−y\u{302}ᵢ)²")
        #expect(MathText.readable(#"-\frac{2}{n}\left(y_{i}-\hat{y}_{i}\right)"#) == "−(2/n)(yᵢ−y\u{302}ᵢ)")
        #expect(MathText.readable(#"x={\frac{-b\pm{\sqrt{b^{2}-4a c}}}{2a}}"#) == "x=(−b±√(b²−4ac))/2a")
        #expect(MathText.readable(#"\sqrt[3]{x}+\sqrt[n]{y}"#) == "∛x+ⁿ√y")
    }

    @Test func aFormulaWithAnythingUnknownStaysAsItsLatex() {
        #expect(MathText.readable(#"\begin{pmatrix}a&b\\c&d\end{pmatrix}"#) == nil)
        #expect(MathText.readable(#"x\foo{y}"#) == nil)
        #expect(MathText.readable(#"\frac{a}{b"#) == nil)
        #expect(MathText.readable("a}b") == nil)
        #expect(MathText.readable("") == nil)
    }

    @Test func textHasEachFormulaItCanMadeReadable() {
        #expect(MathText.readable(in: #"给定损失函数 $L(\theta)$，其中 $\eta>0$ 是学习率。"#) == "给定损失函数 L(θ)，其中 η>0 是学习率。")
        #expect(MathText.readable(in: #"$$x=\frac{1}{2}$$"#) == "x=½")
        #expect(MathText.readable(in: #"see $\foo$ and $x^{2}$"#) == #"see $\foo$ and x²"#)
        #expect(MathText.readable(in: "no formula") == "no formula")
    }
}
