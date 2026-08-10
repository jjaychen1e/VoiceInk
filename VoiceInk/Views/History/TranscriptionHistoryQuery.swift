import Foundation
import SwiftData

/// Shared SwiftData fetch helpers for History list pagination.
enum TranscriptionHistoryQuery {
    /// Builds a page fetch for History, optionally filtering by search and favorites.
    static func cursorDescriptor(
        searchText: String,
        favoritesOnly: Bool,
        after timestamp: Date? = nil,
        pageSize: Int
    ) -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)]
        )

        let search = searchText
        let favOnly = favoritesOnly

        if let timestamp {
            if favOnly && !search.isEmpty {
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    transcription.isFavorite
                        && transcription.timestamp < timestamp
                        && (transcription.text.localizedStandardContains(search)
                            || (transcription.enhancedText?.localizedStandardContains(search) ?? false))
                }
            } else if favOnly {
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    transcription.isFavorite && transcription.timestamp < timestamp
                }
            } else if !search.isEmpty {
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    transcription.timestamp < timestamp
                        && (transcription.text.localizedStandardContains(search)
                            || (transcription.enhancedText?.localizedStandardContains(search) ?? false))
                }
            } else {
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    transcription.timestamp < timestamp
                }
            }
        } else if favOnly && !search.isEmpty {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.isFavorite
                    && (transcription.text.localizedStandardContains(search)
                        || (transcription.enhancedText?.localizedStandardContains(search) ?? false))
            }
        } else if favOnly {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.isFavorite
            }
        } else if !search.isEmpty {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.text.localizedStandardContains(search)
                    || (transcription.enhancedText?.localizedStandardContains(search) ?? false)
            }
        }

        descriptor.fetchLimit = pageSize
        return descriptor
    }

    /// Builds an unpaged descriptor matching the current History filters (for Select All).
    static func matchingAllDescriptor(
        searchText: String,
        favoritesOnly: Bool
    ) -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>()
        let search = searchText
        let favOnly = favoritesOnly

        if favOnly && !search.isEmpty {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.isFavorite
                    && (transcription.text.localizedStandardContains(search)
                        || (transcription.enhancedText?.localizedStandardContains(search) ?? false))
            }
        } else if favOnly {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.isFavorite
            }
        } else if !search.isEmpty {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.text.localizedStandardContains(search)
                    || (transcription.enhancedText?.localizedStandardContains(search) ?? false)
            }
        }

        descriptor.propertiesToFetch = [\.id]
        return descriptor
    }
}
