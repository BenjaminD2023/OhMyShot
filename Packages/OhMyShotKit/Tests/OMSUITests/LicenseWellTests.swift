import Testing
@testable import OMSUI

/// A pack's license as its well shows it.
struct LicenseWellTests {
    @Test func wrappedLinesJoinButAddressesKeepTheirLines() {
        let license = """
        What was changed (Apache License 2.0, section 4(b)): the weights of

            https://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6/tree/c5630ab
            https://huggingface.co/PaddlePaddle/PP-DocLayoutV3_safetensors/tree/e4f489d

        were converted to MLX, by the script in
        https://github.com/fzlzjerry/OhMyShot).
        Nothing was trained or tuned.

              "License" shall mean the terms and conditions for use, reproduction,
              and distribution as defined by Sections 1 through 9 of this document.
        """
        #expect(LicenseWell.reflowed(license) == """
        What was changed (Apache License 2.0, section 4(b)): the weights of

        https://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6/tree/c5630ab
        https://huggingface.co/PaddlePaddle/PP-DocLayoutV3_safetensors/tree/e4f489d

        were converted to MLX, by the script in
        https://github.com/fzlzjerry/OhMyShot).
        Nothing was trained or tuned.

        "License" shall mean the terms and conditions for use, reproduction, and distribution as defined by Sections 1 through 9 of this document.
        """)
    }
}
