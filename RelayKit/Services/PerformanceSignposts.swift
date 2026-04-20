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

import OSLog

/// Centralized performance signposts for profiling hot paths with Instruments.
///
/// Open the Instruments "os_signpost" template and filter by subsystem
/// `"app.subpop.Relay.performance"` to see all intervals. Each category groups
/// related operations:
///
/// - **Timeline**: Diff processing, message mapping, table updates
/// - **RoomList**: Room list rebuilds, room info updates
/// - **Media**: Avatar and media loading, cache hit/miss rates
///
/// Usage:
/// ```swift
/// let state = PerformanceSignposts.timeline.beginInterval("rebuildMessages")
/// // … work …
/// PerformanceSignposts.timeline.endInterval("rebuildMessages", state)
/// ```
nonisolated enum PerformanceSignposts: Sendable {
    /// The shared subsystem for all Relay performance signposts.
    static let subsystem = "app.subpop.Relay.performance"

    // MARK: - Timeline

    /// Signposts for timeline diff processing and message mapping.
    static let timeline = OSSignposter(subsystem: subsystem, category: "Timeline")

    /// Names for timeline signpost intervals.
    nonisolated enum TimelineName: Sendable {
        /// The full pipeline from SDK diff receipt → messages array update.
        static let diffToRender: StaticString = "diffToRender"
        /// Applying raw diffs to the timelineItems array.
        static let applyDiffs: StaticString = "applyDiffs"
        /// The throttle delay between diff receipt and rebuild start.
        static let throttleDelay: StaticString = "throttleDelay"
        /// The incremental message mapping pass (runs off main actor).
        static let rebuildMessages: StaticString = "rebuildMessages"
        /// Applying the mapping result back on the main actor.
        static let applyMappingResult: StaticString = "applyMappingResult"
        /// The equality check between old and new message arrays.
        static let equalityCheck: StaticString = "equalityCheck"
    }

    // MARK: - Timeline Table

    /// Signposts for NSTableView row updates and height measurement.
    static let timelineTable = OSSignposter(subsystem: subsystem, category: "TimelineTable")

    /// Names for timeline table signpost intervals.
    nonisolated enum TimelineTableName: Sendable {
        /// Full updateRows call (structural or content-only).
        static let updateRows: StaticString = "updateRows"
        /// Height measurement via the measurement host.
        static let heightOfRow: StaticString = "heightOfRow"
        /// Invalidating cached heights for a message ID.
        static let invalidateHeight: StaticString = "invalidateHeight"
    }

    // MARK: - Message Mapping

    /// Signposts for the TimelineMessageMapper.
    static let messageMapper = OSSignposter(subsystem: subsystem, category: "MessageMapper")

    /// Names for message mapper signpost intervals.
    nonisolated enum MessageMapperName: Sendable {
        /// The full incremental mapping pass.
        static let mapIncrementally: StaticString = "mapIncrementally"
        /// A single item mapping (FFI + conversion).
        static let mapSingleItem: StaticString = "mapSingleItem"
        /// Cache lookup via FFI event ID extraction.
        static let cacheLookup: StaticString = "cacheLookup"
    }

    // MARK: - Room List

    /// Signposts for room list management.
    static let roomList = OSSignposter(subsystem: subsystem, category: "RoomList")

    /// Names for room list signpost intervals.
    nonisolated enum RoomListName: Sendable {
        /// Rebuilding the sorted room summaries array.
        static let rebuildSummaries: StaticString = "rebuildSummaries"
        /// Applying entry updates from the SDK.
        static let applyEntryUpdates: StaticString = "applyEntryUpdates"
        /// The filteredRooms computed property evaluation.
        static let filterRooms: StaticString = "filterRooms"
    }

    // MARK: - Media

    /// Signposts for media loading and caching.
    static let media = OSSignposter(subsystem: subsystem, category: "Media")

    /// Names for media signpost intervals.
    nonisolated enum MediaName: Sendable {
        /// Avatar thumbnail fetch (cache hit or miss).
        static let avatarThumbnail: StaticString = "avatarThumbnail"
        /// Full media content fetch.
        static let mediaContent: StaticString = "mediaContent"
    }
}
