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

// Full-line selection includes the trailing newline; delimiters must hug
// the text, not spill onto the next line.
tv = makeTV("whole line\nnext", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 11))
tv.toggleBoldMD(nil)
check("bold full line trims newline", tv.string, "**whole line**\nnext")

tv = makeTV("  padded selection  ", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 20))
tv.toggleBoldMD(nil)
check("bold trims spaces", tv.string, "  **padded selection**  ")

// Color spans: apply, swap, and remove by reapplying.
tv = makeTV("color me", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 8))
tv.applyColor(hex: "FF5C5C")
check("color wrap", tv.string, "<span style=\"color:#FF5C5C\">color me</span>")
tv.applyColor(hex: "72A7FF")
check("color swap", tv.string, "<span style=\"color:#72A7FF\">color me</span>")
tv.applyColor(hex: "72A7FF")
check("color remove on reapply", tv.string, "color me")

// A block with mixed colors is repainted, not wrapped around its existing
// spans — wrapping would nest tags the highlighter can't read.
tv = makeTV("hello <span style=\"color:#FF5C5C\">red</span> world", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 50))
tv.applyColor(hex: "72A7FF")
check("color overrides mixed block", tv.string,
      "<span style=\"color:#72A7FF\">hello red world</span>")

// Two spans of one color read as uniform, so reapplying it strips both.
tv = makeTV("<span style=\"color:#FF5C5C\">a</span><span style=\"color:#FF5C5C\">b</span>", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 72))
tv.applyColor(hex: "FF5C5C")
check("color remove across sibling spans", tv.string, "ab")

// Half-covered span: the uncovered tail keeps its color under its own tag
// instead of having the shared close tag stranded.
tv = makeTV("one <span style=\"color:#FF5C5C\">two three</span>", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 35))
tv.applyColor(hex: "72A7FF")
check("color splits partly covered span", tv.string,
      "<span style=\"color:#72A7FF\">one two</span><span style=\"color:#FF5C5C\"> three</span>")

// Spans nested by an earlier version collapse to one on the next apply.
tv = makeTV("<span style=\"color:#FF5C5C\">a<span style=\"color:#55E6A5\">b</span></span>", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 72))
tv.applyColor(hex: "72A7FF")
check("color flattens nested spans", tv.string, "<span style=\"color:#72A7FF\">ab</span>")

// WYSIWYG deletion: backspace after concealed markers removes the visible
// character, not invisible syntax; at a heading start it un-formats.
tv = makeTV("see **bold**", caret: 12)
tv.rehighlight()
tv.deleteBackward(nil)
check("backspace skips hidden delimiters", tv.string, "see **bol**")

tv = makeTV("# Title", caret: 2)
tv.rehighlight()
tv.deleteBackward(nil)
check("backspace at heading start unformats", tv.string, "Title")

tv = makeTV("**bold** tail", caret: 0)
tv.rehighlight()
tv.deleteForward(nil)
check("forward delete skips hidden delimiters", tv.string, "**old** tail")

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

// Bold and italic are layers on the same text, not opaque characters.
tv = makeTV("*word*", caret: 3)
tv.toggleBoldMD(nil)
check("bold on italic layers", tv.string, "***word***")
tv.toggleBoldMD(nil)
check("bold off keeps italic", tv.string, "*word*")

tv = makeTV("**word**", caret: 4)
tv.toggleItalicMD(nil)
check("italic on bold layers", tv.string, "***word***")
tv.toggleItalicMD(nil)
check("italic off keeps bold", tv.string, "**word**")

tv = makeTV("***word***", caret: 5)
tv.toggleBoldMD(nil)
check("unbold combined span", tv.string, "*word*")

tv = makeTV("**word**", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 8))
tv.toggleBoldMD(nil)
check("unwrap with markers selected", tv.string, "word")

tv = makeTV("**word**", caret: 0)
tv.setSelectedRange(NSRange(location: 3, length: 3))
tv.toggleBoldMD(nil)
check("unbold from partial selection", tv.string, "word")

// A selection spanning styled and plain text flattens, then wraps whole.
tv = makeTV("**word** and", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 12))
tv.toggleBoldMD(nil)
check("bold mixed selection", tv.string, "**word and**")

tv = makeTV("*word* and", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 10))
tv.toggleBoldMD(nil)
check("bold mixed keeps italic layer", tv.string, "***word* and**")

tv = makeTV("**word** and", caret: 0)
tv.setSelectedRange(NSRange(location: 4, length: 8))
tv.toggleBoldMD(nil)
check("selection crossing span grows to it", tv.string, "**word and**")

// Sub-range of a span: only that range gets the new layer.
tv = makeTV("**one two**", caret: 0)
tv.setSelectedRange(NSRange(location: 2, length: 3))
tv.toggleItalicMD(nil)
check("italic on part of bold", tv.string, "***one* two**")

tv = makeTV("- item", caret: 6)
tv.insertTab(nil)
check("tab indents list", tv.string, "  - item")
tv.setSelectedRange(NSRange(location: 8, length: 0))
tv.insertBacktab(nil)
check("backtab outdents", tv.string, "- item")

// Typing at the concealed end of an inline span continues its style.
func type(_ tv: EditorTextView, _ s: String) {
    tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
}

tv = makeTV("**bold**", caret: 8)
type(tv, "x")
check("continue bold at end", tv.string, "**boldx**")
type(tv, "y")
check("keep continuing bold", tv.string, "**boldxy**")

tv = makeTV("*word*", caret: 6)
type(tv, "x")
check("continue italic at end", tv.string, "*wordx*")

tv = makeTV("`code`", caret: 6)
type(tv, "x")
check("continue code at end", tv.string, "`codex`")

tv = makeTV("**bold** tail", caret: 8)
type(tv, "x")
check("continue bold mid-line", tv.string, "**boldx** tail")

tv = makeTV("**bold**", caret: 8)
type(tv, " ")
check("space stays outside span", tv.string, "**bold** ")

tv = makeTV("**bold** and", caret: 12)
type(tv, "x")
check("plain text after span unaffected", tv.string, "**bold** andx")

tv = makeTV("<span style=\"color:#FF0000\">red</span>", caret: 38)
type(tv, "x")
check("continue color span at end", tv.string, "<span style=\"color:#FF0000\">redx</span>")

tv = makeTV("**bold**", caret: 0)
type(tv, "x")
check("typing before span unaffected", tv.string, "x**bold**")

tv = makeTV("***word***", caret: 10)
type(tv, "x")
check("continue combined span at end", tv.string, "***wordx***")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
