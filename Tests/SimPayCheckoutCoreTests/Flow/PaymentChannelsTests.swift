import Foundation
import Testing
@testable import SimPayCheckoutCore

@Suite("Payment channels")
struct PaymentChannelsTests {

    private func channel(_ id: String, type: String? = nil, currencies: [String] = ["PLN"], min: Decimal? = nil, max: Decimal? = nil) -> PaymentChannel {
        PaymentChannel(id: id, name: id.uppercased(), type: type, currencies: currencies, minimumAmount: min, maximumAmount: max)
    }

    @Test("BLIK is recognised by id or type, like the Android SDK")
    func blikRecognition() {
        #expect(BlikLevel0.supports(channel("blik")))
        #expect(BlikLevel0.supports(channel("blik-level0")))
        #expect(BlikLevel0.supports(channel(" BLIK_LEVEL_0 ")))
        #expect(BlikLevel0.supports(channel("12", type: "blik")))
        #expect(!BlikLevel0.supports(channel("mbank", type: "transfer")))
    }

    @Test("The two BLIK entries collapse into the Level 0 one at the first BLIK position")
    func collapseToLevel0() {
        let list = [channel("mbank"), channel("blik", type: "blik"), channel("ing"), channel("blik-level0", type: "blik")]
        let collapsed = BlikLevel0.collapseDuplicates(list)

        #expect(collapsed.map(\.id) == ["mbank", "blik-level0", "ing"])
    }

    @Test("A service without Level 0 keeps its plain BLIK entry")
    func keepPlainBlik() {
        let list = [channel("blik", type: "blik"), channel("mbank")]
        #expect(BlikLevel0.collapseDuplicates(list).map(\.id) == ["blik", "mbank"])
    }

    @Test("Collapsing keeps every non-BLIK channel untouched and in order")
    func nonBlikUntouched() {
        let list = [channel("a"), channel("blik"), channel("b"), channel("blik_level_0"), channel("c")]
        #expect(BlikLevel0.collapseDuplicates(list).map(\.id) == ["a", "blik_level_0", "b", "c"])
    }

    @Test("Prepared options put BLIK first")
    func blikFirst() throws {
        let options = ChannelOption.prepare([channel("mbank"), channel("ing"), channel("blik")], for: Sample.order())
        #expect(options.map(\.id) == ["blik", "mbank", "ing"])
        #expect(options.first?.isBlik == true)
    }

    @Test("Availability uses only data the API sent")
    func availability() {
        let order = Sample.order(amount: "100.00")
        #expect(ChannelOption(channel: channel("a"), order: order).isAvailable)
        #expect(ChannelOption(channel: channel("a", currencies: []), order: order).isAvailable)
        #expect(ChannelOption(channel: channel("a", currencies: ["pln"]), order: order).isAvailable)
        #expect(ChannelOption(channel: channel("a", currencies: ["EUR"]), order: order).unavailability == .currencyNotSupported)
        #expect(ChannelOption(channel: channel("a", min: 500), order: order).unavailability == .amountOutOfRange)
        #expect(ChannelOption(channel: channel("a", max: 50), order: order).unavailability == .amountOutOfRange)
        #expect(ChannelOption(channel: channel("a", min: 100, max: 100), order: order).isAvailable)
    }
}
