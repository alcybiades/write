import AppKit

// Headless behavior tests for the editor's list/formatting logic.
// Run with `make test`.

_ = NSApplication.shared

func makeTV(_ content: String, caret: Int) -> EditorTextView {
    let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    tv.configure()
    tv.textStorage?.setAttributedString(NSAttributedString(string: content, attributes: Theme.baseAttributes))
    tv.setSelectedRange(NSRange(location: caret, length: 0))
    return tv
}

var failures = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got == want { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  got:  \(got.debugDescription)\n  want: \(want.debugDescription)") }
}

var tv = makeTV("- hello", caret: 7)
tv.insertNewline(nil)
check("bullet continue", tv.string, "- hello\n- ")

tv = makeTV("- hello\n- ", caret: 10)
tv.insertNewline(nil)
check("empty bullet exits", tv.string, "- hello\n")

tv = makeTV("1. one", caret: 6)
tv.insertNewline(nil)
check("ordered increment", tv.string, "1. one\n2. ")

tv = makeTV("- [ ] task", caret: 10)
tv.insertNewline(nil)
check("task continue", tv.string, "- [ ] task\n- [ ] ")

tv = makeTV("> quoted", caret: 8)
tv.insertNewline(nil)
check("quote continue", tv.string, "> quoted\n> ")

tv = makeTV("plain text", caret: 10)
tv.insertNewline(nil)
check("plain newline", tv.string, "plain text\n")

tv = makeTV("make this bold", caret: 0)
tv.setSelectedRange(NSRange(location: 5, length: 4))
tv.toggleBoldMD(nil)
check("bold wrap", tv.string, "make **this** bold")
tv.toggleBoldMD(nil)
check("bold unwrap", tv.string, "make this bold")

tv = makeTV("hello world", caret: 8)
tv.toggleBoldMD(nil)
check("bold word at caret", tv.string, "hello **world**")

tv = makeTV("Title line", caret: 3)
let item = NSMenuItem(); item.tag = 2
tv.setHeading(item)
check("heading set", tv.string, "## Title line")
item.tag = 1
tv.setHeading(item)
check("heading switch", tv.string, "# Title line")
item.tag = 1
tv.setHeading(item)
check("heading toggle off", tv.string, "Title line")

tv = makeTV("word", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 4))
tv.toggleItalicMD(nil)
check("italic wrap", tv.string, "*word*")

tv = makeTV("- item", caret: 6)
tv.insertTab(nil)
check("tab indents list", tv.string, "  - item")
tv.setSelectedRange(NSRange(location: 8, length: 0))
tv.insertBacktab(nil)
check("backtab outdents", tv.string, "- item")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
