#if os(iOS)
import SwiftUI

/// Channel list: BLIK on top and highlighted, other channels below with their state.
struct ChannelListView: View {

    let list: ChannelList
    let strings: SheetStrings
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(strings.text("channels.choose"))
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if let blik = list.blik {
                ChannelRow(row: blik, strings: strings, onSelect: onSelect)
            }

            if !list.others.isEmpty {
                Text(strings.text("channels.other"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.top, list.blik == nil ? 0 : 8)
                    .accessibilityAddTraits(.isHeader)
                ForEach(list.others) { row in
                    ChannelRow(row: row, strings: strings, onSelect: onSelect)
                }
            }
        }
    }
}

struct ChannelRow: View {

    let row: ChannelList.Row
    let strings: SheetStrings
    let onSelect: (String) -> Void

    @ScaledMetric(relativeTo: .body) private var logoSide: CGFloat = 44

    var body: some View {
        if row.isSelectable {
            Button { onSelect(row.id) } label: { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityValue(row.isBlik ? strings.text("a11y.recommended") : "")
                .accessibilityIdentifier("simpay.channel.\(row.id)")
        } else {
            // An unavailable channel is information, not a control: a dimmed disabled
            // button would drop its text below the contrast minimum.
            content
                .accessibilityElement(children: .combine)
                .accessibilityValue(strings.text("a11y.unavailable"))
                .accessibilityIdentifier("simpay.channel.\(row.id)")
        }
    }

    private var content: some View {
            HStack(spacing: 12) {
                ChannelLogo(row: row, side: logoSide)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.isBlik ? strings.text("channels.blik_name") : row.name)
                        .font(row.isBlik ? .body.weight(.bold) : .body)
                        .foregroundStyle(row.isSelectable ? Color.primary : SheetTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(SheetTheme.secondaryText)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                if row.isSelectable {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SheetTheme.cornerRadius, style: .continuous)
                    .fill(row.isBlik && row.isSelectable ? SheetTheme.highlight : SheetTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SheetTheme.cornerRadius, style: .continuous)
                    .strokeBorder(row.isBlik && row.isSelectable ? SheetTheme.accent : SheetTheme.border,
                                  lineWidth: row.isBlik && row.isSelectable ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: SheetTheme.cornerRadius, style: .continuous))
    }

    private var subtitle: String? {
        switch row.unavailability {
        case nil: return row.isBlik ? strings.text("channels.blik_subtitle") : nil
        case .currencyNotSupported: return strings.text("channels.unavailable_currency")
        case .amountOutOfRange: return strings.text("channels.unavailable_amount")
        }
    }
}

/// Logo from the API (https only), with the first letter of the name behind it, as on
/// Android, so a missing or undecodable image still shows something.
struct ChannelLogo: View {
    let row: ChannelList.Row
    let side: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
            Text(verbatim: String((row.isBlik ? "BLIK" : row.name).prefix(row.isBlik ? 4 : 1)).uppercased())
                .font(.system(size: side * (row.isBlik ? 0.28 : 0.4), weight: .heavy))
                .foregroundStyle(row.isBlik ? Color.black : (row.isSelectable ? SheetTheme.accentText : SheetTheme.secondaryText))
            if let url = row.imageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(6)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SheetTheme.border))
        .saturation(row.isSelectable ? 1 : 0.2)
        .accessibilityHidden(true)
    }
}
#endif
