// Copyright 2026 Link Dupont
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// Which card of a gallery's fanned stack is on top, and how every card
/// is placed relative to it. Cycling wraps, so the card that leaves the
/// top goes to the back of the stack.
struct GalleryDeck: Equatable {
    /// Index of the card currently on top.
    private(set) var top = 0

    /// Cards drawn at once; the rest wait behind the last visible card.
    static let visibleCards = 3

    /// Distance of `index` from the top card: 0 for the top card, 1 for
    /// the card behind it, and so on.
    func position(of index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index - top) % count + count) % count
    }

    func isVisible(_ index: Int, count: Int) -> Bool {
        position(of: index, count: count) < Self.visibleCards
    }

    /// Card indices to draw, back to front.
    func drawOrder(count: Int) -> [Int] {
        (0..<count)
            .filter { isVisible($0, count: count) }
            .sorted { position(of: $0, count: count) > position(of: $1, count: count) }
    }

    /// 1-based number of the top card, for "2 of 5" labels.
    func number(count: Int) -> Int {
        count > 0 ? top % count + 1 : 0
    }

    /// The deck after flipping `steps` cards forward, or backward when
    /// negative. Wraps around.
    func moved(by steps: Int, count: Int) -> GalleryDeck {
        guard count > 0 else { return self }
        var deck = self
        deck.top = ((top + steps) % count + count) % count
        return deck
    }

    mutating func advance(count: Int) {
        guard count > 0 else { return }
        top = (top % count + 1) % count
    }

    mutating func retreat(count: Int) {
        guard count > 0 else { return }
        top = (top % count + count - 1) % count
    }

    // MARK: - Fan Geometry

    /// Rotation of a card in degrees: cards behind the top one fan out
    /// to alternating sides.
    static func angle(forPosition position: Int) -> Double {
        switch position {
        case 0: 0
        case 1: 4
        default: -4
        }
    }

    /// Horizontal offset in points, following the same fan.
    static func offset(forPosition position: Int) -> Double {
        switch position {
        case 0: 0
        case 1: 10
        default: -10
        }
    }

    /// Scale of a card; cards recede as they go back.
    static func scale(forPosition position: Int) -> Double {
        1 - 0.04 * Double(min(position, visibleCards - 1))
    }
}
