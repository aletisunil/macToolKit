import CoreAudio
import Foundation
import Testing
@testable import macToolKit

private func ref(_ uid: String, name: String? = nil,
                 transport: AudioTransport = .usb) -> AudioDeviceRef {
    AudioDeviceRef(uid: uid, name: name ?? uid.uppercased(), transport: transport)
}

private func live(_ uid: String, name: String? = nil,
                  transport: AudioTransport = .usb,
                  out: Int = 2, input: Int = 0) -> LiveAudioDevice {
    LiveAudioDevice(deviceID: 0, uid: uid, name: name ?? uid.uppercased(),
                    transport: transport, outputChannels: out, inputChannels: input)
}

struct AudioPriorityWinnerTests {
    @Test func emptyRankingHasNoWinner() {
        #expect(AudioPriorityController.winner(
            ranked: [], connected: [live("a")], direction: .output) == nil)
    }

    @Test func nothingRankedConnectedHasNoWinner() {
        #expect(AudioPriorityController.winner(
            ranked: [ref("a"), ref("b")], connected: [live("x")],
            direction: .output) == nil)
    }

    @Test func highestRankedConnectedWins() {
        let ranked = [ref("a"), ref("b")]
        #expect(AudioPriorityController.winner(
            ranked: ranked, connected: [live("b"), live("a")],
            direction: .output) == "a")
    }

    @Test func fallsThroughToNextRankWhenTopIsAbsent() {
        let ranked = [ref("a"), ref("b"), ref("c")]
        #expect(AudioPriorityController.winner(
            ranked: ranked, connected: [live("c"), live("b")],
            direction: .output) == "b")
    }

    /// An output-only device must never win the input list.
    @Test func deviceWithoutChannelsInThatDirectionIsSkipped() {
        let ranked = [ref("speakers"), ref("headset")]
        let connected = [live("speakers", out: 2, input: 0),
                         live("headset", out: 2, input: 1)]
        #expect(AudioPriorityController.winner(
            ranked: ranked, connected: connected, direction: .output) == "speakers")
        #expect(AudioPriorityController.winner(
            ranked: ranked, connected: connected, direction: .input) == "headset")
    }

    @Test func unrankedConnectedDevicesAreIgnored() {
        #expect(AudioPriorityController.winner(
            ranked: [ref("b")], connected: [live("a"), live("b"), live("c")],
            direction: .output) == "b")
    }
}

struct AudioPriorityDecideTests {
    private let ranked = [ref("a"), ref("b")]

    private func decide(connected: [String], current: String?, last: String?,
                        trigger: AudioTrigger) -> AudioOutcome {
        AudioPriorityController.decide(
            ranked: ranked,
            connected: connected.map { live($0) },
            direction: .output,
            currentDefaultUID: current,
            lastAppliedUID: last,
            trigger: trigger)
    }

    @Test func featureStartAssertsTheWinner() {
        let outcome = decide(connected: ["a", "b", "x"], current: "x", last: nil,
                             trigger: .featureStart)
        #expect(outcome == AudioOutcome(apply: "a", winner: "a"))
    }

    @Test func winnerAlreadyDefaultIsNeverSetAgain() {
        for trigger in [AudioTrigger.featureStart, .deviceSetChanged] {
            let outcome = decide(connected: ["a", "b"], current: "a", last: "a",
                                 trigger: trigger)
            #expect(outcome == AudioOutcome(apply: nil, winner: "a"))
        }
    }

    /// The manual-pick guarantee: an unrelated device-list event must not undo
    /// a device the user chose by hand.
    @Test func deviceSetChangeLeavesAManualPickAlone() {
        let outcome = decide(connected: ["a", "b", "x", "usbhub"],
                             current: "x", last: "a", trigger: .deviceSetChanged)
        #expect(outcome == AudioOutcome(apply: nil, winner: "a"))
    }

    @Test func topDeviceUnpluggedFallsToTheNextRank() {
        let outcome = decide(connected: ["b", "x"], current: "x", last: "a",
                             trigger: .deviceSetChanged)
        #expect(outcome == AudioOutcome(apply: "b", winner: "b"))
    }

    @Test func topDeviceRepluggedTakesOverAgain() {
        let outcome = decide(connected: ["a", "b", "x"], current: "b", last: "b",
                             trigger: .deviceSetChanged)
        #expect(outcome == AudioOutcome(apply: "a", winner: "a"))
    }

    @Test func lowerRankedDeviceArrivingChangesNothing() {
        let outcome = decide(connected: ["a", "b"], current: "a", last: "a",
                             trigger: .deviceSetChanged)
        #expect(outcome == AudioOutcome(apply: nil, winner: "a"))
    }

    /// Nothing ranked is present: leave macOS's own choice alone and clear the
    /// remembered winner, so the device returning later counts as a change.
    @Test func nothingRankedConnectedIsANoOpAndResetsLastApplied() {
        for trigger in [AudioTrigger.featureStart, .deviceSetChanged] {
            let outcome = decide(connected: ["x", "y"], current: "x", last: "b",
                                 trigger: trigger)
            #expect(outcome == AudioOutcome(apply: nil, winner: nil))
        }
    }

    @Test func rankedDeviceReturningAfterNoneWasPresentIsApplied() {
        let outcome = decide(connected: ["a", "x"], current: "x", last: nil,
                             trigger: .deviceSetChanged)
        #expect(outcome == AudioOutcome(apply: "a", winner: "a"))
    }
}

struct AudioPriorityNameRefreshTests {
    @Test func connectedDeviceUpdatesTheCachedLabel() {
        let stored = [ref("a", name: "Old Name", transport: .usb)]
        let refreshed = AudioPriorityController.refreshingNames(
            stored, from: [live("a", name: "New Name", transport: .bluetooth)])
        #expect(refreshed.first?.name == "New Name")
        #expect(refreshed.first?.transport == .bluetooth)
    }

    @Test func offlineEntryKeepsItsStoredLabel() {
        let stored = [ref("a", name: "Studio Display"), ref("b", name: "AirPods")]
        let refreshed = AudioPriorityController.refreshingNames(
            stored, from: [live("a", name: "Studio Display")])
        #expect(refreshed.map(\.name) == ["Studio Display", "AirPods"])
    }
}

struct AudioTransportTests {
    @Test func mapsKnownHALCodes() {
        #expect(AudioTransport(hal: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
        #expect(AudioTransport(hal: kAudioDeviceTransportTypeUSB) == .usb)
        #expect(AudioTransport(hal: kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        #expect(AudioTransport(hal: kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
        #expect(AudioTransport(hal: kAudioDeviceTransportTypeHDMI) == .hdmi)
        #expect(AudioTransport(hal: kAudioDeviceTransportTypeAggregate) == .aggregate)
        #expect(AudioTransport(hal: kAudioDeviceTransportTypeVirtual) == .virtual)
        #expect(AudioTransport(hal: kAudioDeviceTransportTypeContinuityCaptureWireless)
            == .continuity)
    }

    @Test func unknownCodeFallsBackToOther() {
        #expect(AudioTransport(hal: 0) == .other)
        #expect(AudioTransport(hal: 0xDEAD_BEEF) == .other)
    }

    @Test func everyTransportHasASymbolInBothDirections() {
        let all: [AudioTransport] = [.builtIn, .usb, .bluetooth, .hdmi, .displayPort,
                                     .thunderbolt, .airPlay, .firewire, .pci, .avb,
                                     .aggregate, .virtual, .continuity, .other]
        for transport in all {
            for direction in AudioDirection.allCases {
                #expect(!transport.symbol(for: direction).isEmpty)
            }
        }
    }
}

@MainActor
struct AudioPriorityStoreTests {
    /// A scratch defaults domain per test, so nothing here touches the app's
    /// real preferences.
    private func makeStore(seed: [AudioDeviceRef] = []) -> (AudioPriorityStore, UserDefaults) {
        let suite = "AudioPriorityStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = AudioPriorityStore(key: "entries", defaults: defaults)
        store.entries = seed
        return (store, defaults)
    }

    @Test func addAppendsAndSkipsDuplicates() {
        let (store, _) = makeStore()
        store.add(live("a"))
        store.add(live("b"))
        store.add(live("a"))
        #expect(store.entries.map(\.uid) == ["a", "b"])
        #expect(store.contains(uid: "b"))
        #expect(!store.contains(uid: "c"))
    }

    @Test func entriesSurviveAReload() {
        let (store, defaults) = makeStore()
        store.add(live("a", name: "AirPods", transport: .bluetooth))
        store.add(live("b", name: "Studio Display"))
        store.remove(uid: "a")

        let reloaded = AudioPriorityStore(key: "entries", defaults: defaults)
        #expect(reloaded.entries == store.entries)
        #expect(reloaded.entries.map(\.name) == ["Studio Display"])
    }

    @Test func editingTheListNotifiesTheController() {
        let (store, _) = makeStore()
        var changes = 0
        store.onChange = { changes += 1 }

        store.add(live("a"))
        store.add(live("b"))
        store.entries.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        store.remove(uid: "a")
        #expect(changes == 4)

        // A no-op write must not count as an edit.
        store.entries = store.entries
        store.remove(uid: "not-there")
        #expect(changes == 4)
    }

    /// The invariant that keeps a rename in Audio MIDI Setup from switching
    /// devices: refreshed labels are persisted but never reported as an edit.
    @Test func refreshingNamesIsSilent() {
        let (store, defaults) = makeStore(seed: [ref("a", name: "Old Name")])
        var changes = 0
        store.onChange = { changes += 1 }

        store.refreshNames(from: [live("a", name: "New Name", transport: .bluetooth)])
        #expect(changes == 0)
        #expect(store.entries.map(\.name) == ["New Name"])

        let reloaded = AudioPriorityStore(key: "entries", defaults: defaults)
        #expect(reloaded.entries.map(\.name) == ["New Name"])

        // Still silent, and still an edit afterwards.
        store.refreshNames(from: [live("a", name: "New Name", transport: .bluetooth)])
        #expect(changes == 0)
        store.remove(uid: "a")
        #expect(changes == 1)
    }
}

struct AudioDeviceRefCodingTests {
    @Test func roundTripsThroughJSON() throws {
        let entries = [ref("uid-1", name: "AirPods Pro", transport: .bluetooth),
                       ref("uid-2", name: "Studio Display", transport: .displayPort)]
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([AudioDeviceRef].self, from: data)
        #expect(decoded == entries)
    }
}
