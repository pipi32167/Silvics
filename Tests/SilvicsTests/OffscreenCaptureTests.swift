import XCTest
@testable import Silvics

/// 离屏通道里能脱离界面验证的两块：画布尺寸解析、空白图判定。
/// 真正的渲染只能在无窗口会话里跑进程验（见 `/tmp/silvics-offscreen.log`）。
final class OffscreenCaptureTests: XCTestCase {

    func testParseSizeReadsWidthAndHeight() {
        let parsed = OffscreenCapture.parseSize("1280x900")
        XCTAssertEqual(parsed.size.width, 1280)
        XCTAssertEqual(parsed.size.height, 900)
        XCTAssertNil(parsed.warning)
    }

    func testParseSizeAcceptsUppercaseX() {
        let parsed = OffscreenCapture.parseSize("1440X1000")
        XCTAssertEqual(parsed.size.width, 1440)
        XCTAssertEqual(parsed.size.height, 1000)
        XCTAssertNil(parsed.warning)
    }

    func testParseSizeFallsBackWithWarningOnGarbage() {
        for raw in ["1280", "abc", "0x900", "1280x", "x900"] {
            let parsed = OffscreenCapture.parseSize(raw)
            XCTAssertEqual(parsed.size, OffscreenCapture.defaultSize, "输入 \(raw) 应退回默认画布")
            XCTAssertNotNil(parsed.warning, "输入 \(raw) 必须留下失败原因")
        }
    }

    func testParseSizeSilentOnMissingValue() {
        // 没设这个变量不是错误，不该写告警。
        XCTAssertNil(OffscreenCapture.parseSize(nil).warning)
        XCTAssertNil(OffscreenCapture.parseSize("").warning)
        XCTAssertEqual(OffscreenCapture.parseSize(nil).size, OffscreenCapture.defaultSize)
    }

    func testBlankVerdictFlagsSingleColourImage() {
        let rep = makeRep(fill: { _ in (255, 255, 255) })
        XCTAssertNotNil(OffscreenCapture.blankVerdict(rep), "单色图必须被判成疑似空白")
    }

    func testBlankVerdictPassesVariedImage() {
        let rep = makeRep(fill: { index in (UInt8(index % 256), UInt8((index / 3) % 256), UInt8((index * 7) % 256)) })
        XCTAssertNil(OffscreenCapture.blankVerdict(rep), "有色块内容的图不该被判成空白")
    }

    private func makeRep(fill: (Int) -> (UInt8, UInt8, UInt8)) -> NSBitmapImageRep {
        let side = 64
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        guard let data = rep.bitmapData else {
            XCTFail("位图数据取不到")
            return rep
        }
        let bytesPerPixel = rep.bitsPerPixel / 8
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let offset = y * rep.bytesPerRow + x * bytesPerPixel
                let (r, g, b) = fill(y * rep.pixelsWide + x)
                data[offset] = r
                data[offset + 1] = g
                data[offset + 2] = b
                if bytesPerPixel > 3 { data[offset + 3] = 255 }
            }
        }
        return rep
    }
}
