#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import SimPayCheckout
@testable import SimPayCheckoutCore

/// Smoke tests that lay out and draw the real sheet in a window on the simulator, in light
/// and dark mode, in both languages and with accessibility text sizes. They check that
/// every screen lays out and draws content, and they write PNG
/// snapshots for visual review when `SIMPAY_SNAPSHOT_DIR` is set
/// (`TEST_RUNNER_SIMPAY_SNAPSHOT_DIR=/tmp/shots xcodebuild test ...`).
@MainActor
@Suite("Payment sheet rendering", .serialized)
struct PaymentSheetRenderingTests {

    struct Variant: CustomTestStringConvertible, Sendable {
        let name: String
        let screen: PaymentSheetScreen
        var blikCode = ""
        var language = "pl"
        var dark = false
        var textSize: DynamicTypeSize = .large
        var paymentPage: URL?
        var testDescription: String { name }
    }

    nonisolated private static let id = Sheet.transactionID
    nonisolated private static let list = ChannelList(
        [
            ChannelOption(channel: PaymentChannel(id: "blik-level0", name: "BLIK Level 0", currencies: ["PLN"]), order: Sheet.order()),
            ChannelOption(channel: PaymentChannel(id: "mbank", name: "mBank", currencies: ["PLN"]), order: Sheet.order()),
            ChannelOption(channel: PaymentChannel(id: "pekao", name: "Pekao24", currencies: ["PLN"]), order: Sheet.order()),
            ChannelOption(channel: PaymentChannel(id: "sepa", name: "SEPA", currencies: ["EUR"]), order: Sheet.order()),
        ]
    )
    nonisolated private static let freshEntry = BlikEntry(transactionID: nil, problem: nil, remainingAttempts: 5)
    nonisolated private static let rejectedEntry = BlikEntry(transactionID: nil, problem: .codeRejected, remainingAttempts: 4)

    nonisolated static let variants: [Variant] = [
        Variant(name: "01-channels-pl", screen: .channels(list)),
        Variant(name: "02-blik-pl", screen: .blikEntry(freshEntry, canChangeMethod: true), blikCode: "482"),
        Variant(name: "03-blik-rejected-pl", screen: .blikEntry(rejectedEntry, canChangeMethod: true)),
        Variant(name: "04-preparing-pl", screen: .progress(.preparingPayment)),
        Variant(name: "05-awaiting-bank-pl", screen: .awaitingBank),
        Variant(name: "06-success-pl", screen: .result(.succeeded(transactionID: id, status: .paid))),
        Variant(name: "07-pending-pl", screen: .result(.pending(transactionID: id, status: .new, reason: .inProgress))),
        Variant(name: "08-outcome-unknown-pl", screen: .result(.outcomeUnknown(SimPayCheckoutError(.outcomeUnknown)))),
        Variant(name: "09-failed-pl", screen: .result(.failed(SimPayCheckoutError(.transactionFailed), transactionID: id, status: .failure))),
        Variant(name: "10-channels-error-pl", screen: .failure(SimPayCheckoutError(.noInternet), canRetry: true)),
        Variant(name: "11-loading-pl", screen: .loadingChannels),
        Variant(name: "12-channels-dark-pl", screen: .channels(list), dark: true),
        Variant(name: "13-blik-dark-pl", screen: .blikEntry(freshEntry, canChangeMethod: true), blikCode: "482913", dark: true),
        Variant(name: "14-channels-en", screen: .channels(list), language: "en"),
        Variant(name: "15-awaiting-bank-en", screen: .awaitingBank, language: "en"),
        Variant(name: "16-channels-ax3-pl", screen: .channels(list), textSize: .accessibility3),
        Variant(name: "17-blik-ax3-pl", screen: .blikEntry(freshEntry, canChangeMethod: true), blikCode: "48", textSize: .accessibility3),
        Variant(name: "18-redirect-pl", screen: .redirecting, paymentPage: Sheet.paymentPage),
        Variant(name: "19-checking-after-return-pl", screen: .progress(.checkingStatus), paymentPage: Sheet.paymentPage),
    ]

    @Test("Every screen renders in a window", arguments: variants)
    func render(_ variant: Variant) async throws {
        let strings = SheetStrings(language: variant.language)
        let (model, _, _) = Sheet.model(SheetTransport())
        model.showForPreview(variant.screen, blikCode: variant.blikCode, paymentPage: variant.paymentPage)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.overrideUserInterfaceStyle = variant.dark ? .dark : .light
        let sheet = UIHostingController(rootView: AnyView(
            PaymentSheetView(model: model, strings: strings)
                .environment(\.dynamicTypeSize, variant.textSize)
                .environment(\.locale, strings.locale)
        ))
        // The package test host has no UIApplication, so UIKit never runs a sheet
        // transition there: the sheet content is hosted directly in the window. The
        // grabber and rounded top come from the system sheet at runtime.
        window.rootViewController = sheet
        window.isHidden = false
        try await Task.sleep(for: .milliseconds(250))
        sheet.view.layoutIfNeeded()

        // Without a render server `drawHierarchy` draws nothing; the layer tree does.
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.layer.render(in: context.cgContext)
        }
        #expect(image.size == window.bounds.size)
        #expect(sheet.view.window != nil)

        #expect(Self.distinctColors(in: image) > 8, "\(variant.name) rendered an empty screen")

        if let directory = ProcessInfo.processInfo.environment["SIMPAY_SNAPSHOT_DIR"], let data = image.pngData() {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(variant.name).png"))
        }
        window.isHidden = true
    }

    /// Number of distinct colours on a coarse grid; a blank or failed render has one or two.
    private static func distinctColors(in image: UIImage) -> Int {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        var colours = Set<UInt32>()
        for y in stride(from: 0, to: cgImage.height, by: 12) {
            for x in stride(from: 0, to: cgImage.width, by: 12) {
                let offset = y * cgImage.bytesPerRow + x * bytesPerPixel
                colours.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
            }
        }
        return colours.count
    }
}
#endif
