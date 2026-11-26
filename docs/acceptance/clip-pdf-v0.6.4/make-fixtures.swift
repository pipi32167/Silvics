import AppKit
import PDFKit

func makePDF(pages: [String], title: String?, password: String?) -> Data {
    let buffer = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let consumer = CGDataConsumer(data: buffer as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
    for text in pages {
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont(name: "PingFangSC-Regular", size: 13) ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.black,
            .paragraphStyle: style,
        ])
        attributed.draw(in: CGRect(x: 48, y: 560, width: 499, height: 230))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }
    context.closePDF()
    var out = buffer as Data
    if let doc = PDFDocument(data: out) {
        if let title { doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] = title }
        if let password {
            let url = URL(fileURLWithPath: "/tmp/pdf-fix/_tmp.pdf")
            let options: [PDFDocumentWriteOption: Any] = [
                PDFDocumentWriteOption.userPasswordOption: password,
                PDFDocumentWriteOption.ownerPasswordOption: password,
            ]
            _ = doc.write(to: url, withOptions: options)
            out = (try? Data(contentsOf: url)) ?? out
        } else if let rewritten = doc.dataRepresentation() {
            out = rewritten
        }
    }
    return out
}

let zh = """
写作工具的摩擦成本

写长文的时候，工具的手感决定写作频率。启动慢、光标跳、预览延迟，都会让人少写一段。

输入即渲染、没有保存按钮的工具，更让人愿意随手记。这不是审美问题，是摩擦成本问题。

第二页继续：把每次切换窗口、每次等待预览的时间加总，一周能吃掉好几个小时。
"""

let en = """
The friction cost of writing tools

When the tool is slow to launch, jumps the cursor, or lags on preview, you write less.

Editors that render as you type and have no save button make it easy to jot things down.

Page two: count every window switch and every preview delay; a week of them costs hours.
"""

let big = (1...61).map { index in
    """
    第 \(index) 页

    这一页用来验证按页截断。写作工具的摩擦成本会随着页数累积，六十页之后只保留前六十页。

    末尾标记不应该出现在第六十一页。
    """
}

try! makePDF(pages: [zh, zh], title: "写作工具的摩擦成本", password: nil).write(to: URL(fileURLWithPath: "/tmp/pdf-fix/zh.pdf"))
try! makePDF(pages: [en, en], title: "The friction cost of writing tools", password: nil).write(to: URL(fileURLWithPath: "/tmp/pdf-fix/en.pdf"))
try! makePDF(pages: [""], title: "扫描件示例", password: nil).write(to: URL(fileURLWithPath: "/tmp/pdf-fix/scanned.pdf"))
try! makePDF(pages: [zh, zh], title: "加密报告", password: "1234").write(to: URL(fileURLWithPath: "/tmp/pdf-fix/encrypted.pdf"))
try! makePDF(pages: big, title: "第 1 到 61 页的长报告", password: nil).write(to: URL(fileURLWithPath: "/tmp/pdf-fix/long61.pdf"))
print("done")
