import SwiftUI
import UIKit

/// Renders truncated text with a styled "MORE" suffix that always stays inline at the end of the
/// last visible line — never pushed to its own line, and never itself clipped by truncation.
///
/// SwiftUI's built-in `.lineLimit` + `.truncationMode(.tail)` truncates from the end of the string,
/// which would cut off a trailing "MORE" suffix on any text long enough to need truncation. This
/// view instead measures the text against the view's actual width and manually truncates at a word
/// boundary, reserving space for the suffix so it always survives.
struct InlineMoreText: View {
    private let text: String
    private let textStyle: UIFont.TextStyle
    private let textWeight: UIFont.Weight
    private let textColor: Color
    private let moreSuffix: String
    private let moreTextStyle: UIFont.TextStyle
    private let moreWeight: UIFont.Weight
    private let moreColor: Color
    private let lineLimit: Int
    private let alignment: TextAlignment

    @State private var availableWidth: CGFloat = 0

    init(
        _ text: String,
        textStyle: UIFont.TextStyle = .footnote,
        textWeight: UIFont.Weight = .regular,
        textColor: Color,
        moreText: String = "MORE",
        moreTextStyle: UIFont.TextStyle? = nil,
        moreWeight: UIFont.Weight = .semibold,
        moreColor: Color,
        lineLimit: Int,
        alignment: TextAlignment = .leading
    ) {
        self.text = text
        self.textStyle = textStyle
        self.textWeight = textWeight
        self.textColor = textColor
        self.moreSuffix = " \(moreText)"
        self.moreTextStyle = moreTextStyle ?? textStyle
        self.moreWeight = moreWeight
        self.moreColor = moreColor
        self.lineLimit = lineLimit
        self.alignment = alignment
    }

    var body: some View {
        Text(attributedText)
            .multilineTextAlignment(alignment)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                availableWidth = newWidth
            }
    }

    private var primaryFont: UIFont {
        Self.uiFont(style: textStyle, weight: textWeight)
    }

    private var moreFont: UIFont {
        Self.uiFont(style: moreTextStyle, weight: moreWeight)
    }

    private static func uiFont(style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        guard weight != .regular else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private var attributedText: AttributedString {
        guard availableWidth > 0 else {
            return rendered(bodyText: text)
        }

        let maxHeight = maxHeight(width: availableWidth)

        if height(of: measurable(bodyText: text), width: availableWidth) <= maxHeight {
            return rendered(bodyText: text)
        }

        let words = text.split(separator: " ").map(String.init)
        var low = 0
        var high = words.count
        var bestFit: String?

        while low <= high {
            let mid = (low + high) / 2
            guard mid > 0 else { break }
            let candidateText = words[0..<mid].joined(separator: " ") + "\u{2026}"
            if height(of: measurable(bodyText: candidateText), width: availableWidth) <= maxHeight {
                bestFit = candidateText
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return rendered(bodyText: bestFit ?? "\u{2026}")
    }

    private func rendered(bodyText: String) -> AttributedString {
        var body = AttributedString(bodyText)
        body.font = Font(primaryFont as CTFont)
        body.foregroundColor = textColor

        var more = AttributedString(moreSuffix)
        more.font = Font(moreFont as CTFont)
        more.foregroundColor = moreColor

        return body + more
    }

    private func measurable(bodyText: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: bodyText, attributes: [.font: primaryFont])
        result.append(NSAttributedString(string: moreSuffix, attributes: [.font: moreFont]))
        return result
    }

    /// Measures the exact height `lineLimit` lines of `primaryFont` occupy, using the same
    /// `boundingRect` method used elsewhere. `UIFont.lineHeight * lineLimit` is not a reliable
    /// substitute — TextKit's actual line-wrapping height doesn't match it closely enough, which
    /// previously caused truncation to stop a full line short of the allowed limit.
    private func maxHeight(width: CGFloat) -> CGFloat {
        let reference = NSAttributedString(
            string: Array(repeating: "Ag", count: lineLimit).joined(separator: "\n"),
            attributes: [.font: primaryFont]
        )
        return ceil(height(of: reference, width: width)) + 0.5
    }

    private func height(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        InlineMoreText(
            "This is a short bio that should fit without needing to truncate at all.",
            textStyle: .body,
            textColor: .primary,
            moreTextStyle: .subheadline,
            moreWeight: .bold,
            moreColor: .secondary,
            lineLimit: 3
        )

        InlineMoreText(
            "This is a much longer biography that goes on for quite a while describing the artist's history, influences, and discography in detail so that it definitely needs to be truncated to fit within the line limit provided here.",
            textStyle: .body,
            textColor: .primary,
            moreTextStyle: .subheadline,
            moreWeight: .bold,
            moreColor: .secondary,
            lineLimit: 3
        )
    }
    .padding()
}
