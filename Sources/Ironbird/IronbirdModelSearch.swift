//
//           /\
//          |  |                       Blackbird
//          |  |
//         .|  |.       https://github.com/marcoarment/Blackbird
//         $    $
//        /$    $\          Copyright 2022–2023 Marco Arment
//       / $|  |$ \          Released under the MIT License
//      .__$|  |$__.
//           \/
//
//  BlackbirdModelSearch.swift
//  Created by Marco Arment on 10/23/23.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import SQLite3

/// Defines a searchable field for a full-text index in a ``IronbirdModel/fullTextSearchableColumns`` dictionary.
public struct IronbirdModelFullTextSearchableColumn: Equatable, Hashable, Sendable {
	/// This column should be indexed as a text column, and can be used with `.match()` operations, with the default weight of `1.0`.
	public static var text: Self { .init(weight: 1.0, indexed: true) }

	/// This column should be indexed as a text column, and can be used with `.match()` operations.
	/// - Parameters:
	///   - weight: The weight of this column for search relevance, relative to other indexed columns. Default is `1.0`.
	public static func text(weight: Double = 1.0) -> Self { .init(weight: weight, indexed: true) }

	/// This column should be present in the index for filtering with `WHERE` clauses, but not indexed as text or usable with `.match()` operations.
	public static var filterOnly: Self { .init(weight: 0, indexed: false) }

	let weight: Double
	let indexed: Bool

	private init(weight: Double, indexed: Bool) {
		self.weight = weight
		self.indexed = indexed
	}

	public func hash(into hasher: inout Hasher) {
		hasher.combine(self.weight)
		hasher.combine(self.indexed)
	}
}

/// Options for full-text-search queries.
public struct IronbirdModelSearchOptions<T: IronbirdModel>: Sendable {
	public enum HighlightMode: Sendable {
		/// Do not generate highlights.
		case none

		/// Generate copies of the source text that highlight occurrences of the search terms.
		///
		/// ## Example
		/// Given:
		/// * Source text:  `"a b c d e d c b a"`
		/// * Search query: `"c"`
		/// * A prefix of `"<b>"`
		/// * A suffix of `"</b>"`
		///
		/// The resulting highlight would be:
		///
		/// `"a b <b>c</b> d e d <b>c</b> b a"`
		case generate(prefix: String, suffix: String)
	}

	public enum SnippetMode: Sendable {
		/// Do not generate snippets.
		case none

		/// Generate snippets that highlight the best match of the given search terms in the source text.
		///
		/// ## Example
		/// Given:
		/// * Source text:  `"a b c d e"`
		/// * Search query: `"c"`
		/// * 3 context words
		/// * A prefix of `"<b>"`
		/// * A suffix of `"</b>"`
		/// * An ellipsis of `"…"`
		///
		/// The resulting snippet would be:
		///
		/// `"…b <b>c</b> d…"`
		case generate(contextWords: Int, prefix: String, suffix: String, ellipsis: String)
	}

	/// Whether and how to highlight search terms in results.
	let highlights: HighlightMode

	/// Whether and how to generate snippets showing search terms in results.
	let snippets: SnippetMode

	/// If `true`, every instance in search results will be prefetched and available from the ``IronbirdModelSearchResult/preloadedInstance`` property.
	let preloadInstances: Bool

	/// If set, relevance scores are multiplied by the numeric value in this column for search ranking. Results with higher values in this column will be ranked higher. This column must be in the full-text index.
	///
	/// Can be used simultaneously with ``scoreMultiple``. Scores will be multiplied by both values.
	let scoreMultipleColumn: T.IronbirdColumnKeyPath?

	/// If set, all result scores in this query are multiplied by this value. Useful when merging the results of multiple searches, such as when performing secondary searches for spelling-corrected queries.
	///
	/// Can be used simultaneously with ``scoreMultipleColumn``. Scores will be multiplied by both values.
	let scoreMultiple: Double

	let orderBy: [IronbirdModelOrderClause<T>]

	/// The default options: generate highlights and snippets, preload instances, and use only relevance-based ranking.
	public static var `default`: Self { .init() }

	public init(highlights: HighlightMode = .generate(prefix: "<b>", suffix: "</b>"), snippets: SnippetMode = .generate(contextWords: 7, prefix: "<b>", suffix: "</b>", ellipsis: "…"), preloadInstances: Bool = true, scoreMultiple: Double = 1.0, scoreMultipleColumn: T.IronbirdColumnKeyPath? = nil, orderBy: IronbirdModelOrderClause<T> ...) {
		self.highlights = highlights
		self.snippets = snippets
		self.preloadInstances = preloadInstances
		self.scoreMultiple = scoreMultiple
		self.scoreMultipleColumn = scoreMultipleColumn
		self.orderBy = orderBy
	}

	public init(highlights: HighlightMode = .generate(prefix: "<b>", suffix: "</b>"), snippets: SnippetMode = .generate(contextWords: 7, prefix: "<b>", suffix: "</b>", ellipsis: "…"), preloadInstances: Bool = true, scoreMultiple: Double = 1.0, scoreMultipleColumn: T.IronbirdColumnKeyPath? = nil, orderBy: [IronbirdModelOrderClause<T>]) {
		self.highlights = highlights
		self.snippets = snippets
		self.preloadInstances = preloadInstances
		self.scoreMultiple = scoreMultiple
		self.scoreMultipleColumn = scoreMultipleColumn
		self.orderBy = orderBy
	}
}

/// A matching model from a full-text search query, with snippets to highlight the query in the source text.
public struct IronbirdModelSearchResult<T: IronbirdModel>: Identifiable, Sendable {
	/// Intended only for `Identifiable` conformance, not external use.
	public var id: Ironbird.Value { self.rowid }

	/// The score of this item within the search that generated it. Results with higher values were ranked earlier and considered more relevant than those with lower values.
	///
	/// Values are only meaningful as relative relevance within their search, not as an absolute scale or indicator of anything outside the context of the search that generated them.
	public let score: Double

	private let highlights: Ironbird.ModelRow<T>?
	private let highlightMode: IronbirdModelSearchOptions<T>.HighlightMode
	private let snippets: Ironbird.ModelRow<T>?
	private let snippetMode: IronbirdModelSearchOptions<T>.SnippetMode
	private let rowid: Ironbird.Value

	/// Merge results from multiple searches.
	/// - Parameter results: A list of result arrays.
	/// - Returns: A single result array containing all elements of the input arrays, with duplicates removed, and with each element bearing its highest score among all occurrences in the input arrays.
	public static func merge(results: [Self]...) -> [Self] {
		var allResults: [Self] = []
		for resultSet in results {
			allResults.append(contentsOf: resultSet)
		}

		// Sort by rowid, then highest-scoring version
		allResults.sort { a, b in
			if a.rowid == b.rowid { return a.score > b.score }
			return a.rowid > b.rowid
		}

		// Create array with only the first copy of each rowid, which will now have the highest score
		var mergedResults: [Self] = []
		var rowids = Set<Ironbird.Value>()
		for result in allResults {
			let (inserted, _) = rowids.insert(result.rowid)
			if inserted { mergedResults.append(result) }
		}

		// sort by score
		mergedResults.sort { $0.score > $1.score }

		return mergedResults
	}

	/// The preloaded instance for this search result if ``IronbirdModelSearchOptions`` specified `preloadInstances` for the search query.
	public let preloadedInstance: T?

	init(highlights: Ironbird.ModelRow<T>?, highlightMode: IronbirdModelSearchOptions<T>.HighlightMode, snippets: Ironbird.ModelRow<T>?, snippetMode: IronbirdModelSearchOptions<T>.SnippetMode, rowid: Ironbird.Value, score: Double, preloadedInstance: T?) {
		self.highlights = highlights
		self.highlightMode = highlightMode
		self.snippets = snippets
		self.snippetMode = snippetMode
		self.rowid = rowid
		self.score = score
		self.preloadedInstance = preloadedInstance
	}

	/// The full model instance for this search result.
	/// - Parameter database: The ``Ironbird/Database`` to read from.
	/// - Returns: The specified instance, or `nil` if it no longer exists in the database.
	public func instance(from database: Ironbird.Database) async throws -> T? {
		if let preloadedInstance { return preloadedInstance }
		return try await self.instanceIsolated(from: database, core: database.core)
	}

	/// Synchronous version of ``instance(from:)`` for use in database transactions.
	public func instanceIsolated(from database: Ironbird.Database, core: isolated Ironbird.Database.Core) throws -> T? {
		if let preloadedInstance { return preloadedInstance }
		return try T.readIsolated(from: database, core: core, sqlWhere: "rowid = ?", arguments: [self.rowid]).first
	}

	/// A subset of columns from this search result's model row.
	/// - Parameters:
	///   - database: The ``Ironbird/Database`` to read from.
	///   - columns: The column key-paths to select.
	/// - Returns: A ``Ironbird/ModelRow`` of the model's type with only the specified columns present.
	public func row(from database: Ironbird.Database, columns: [T.IronbirdColumnKeyPath]) async throws -> Ironbird.ModelRow<T>? {
		try await self.rowIsolated(from: database, core: database.core, columns: columns)
	}

	/// Synchronous version of ``row(from:columns:)`` for use in database transactions.
	public func rowIsolated(from database: Ironbird.Database, core: isolated Ironbird.Database.Core, columns: [T.IronbirdColumnKeyPath]) throws -> Ironbird.ModelRow<T>? {
		try T.queryIsolated(in: database, core: core, columns: columns, matching: .literal("rowid = ?", self.rowid)).first
	}

	/// The text of the given column, with the highlighting prefix and suffix strings, if this column matched the search query.
	/// - Parameter column: The desired column key-path.
	/// - Returns: The source text with matches surrounded by the highlight prefix and suffix strings, or `nil` if highlights were not generated by the search.
	public func highlighted(_ column: T.IronbirdColumnKeyPath) -> String? {
		if case .generate = self.highlightMode, let text = highlights?.value(keyPath: column)?.stringValue {
			return text
		} else {
			return nil
		}
	}

	/// A snippet of matching text, with the snippet-highlighting prefix and suffix strings, if this column matched the search query.
	/// - Parameter column: The desired column key-path.
	/// - Returns: The snippet of matching text with matches surrounded by the snippet prefix and suffix strings, or `nil` if this column didn't match the query or snippets were not generated by the search.
	public func snippet(_ column: T.IronbirdColumnKeyPath) -> String? {
		if case .generate(_, let prefix, let suffix, _) = snippetMode, let text = snippets?.value(keyPath: column)?.stringValue, text.contains(prefix), text.contains(suffix) {
			return text
		} else {
			return nil
		}
	}

	/// The text of the given column, with matches highlighted, if this column matched the search query.
	/// - Parameters:
	///   - column: The desired column key-path.
	///   - matchAttributes: The attributes to apply to matching substrings.
	/// - Returns: The source text with matches having the given attributes, or `nil` if highlights were not generated by the search.
	public func highlighted(_ column: T.IronbirdColumnKeyPath, matchAttributes: AttributeContainer) -> AttributedString? {
		guard case .generate(let prefix, let suffix) = highlightMode, let text = highlights?.value(keyPath: column)?.stringValue else { return nil }
		return self.higlightedText(text, prefix: prefix, suffix: suffix, matchAttributes: matchAttributes)
	}

	/// A snippet of matching text, with matches highlighted, if this column matched the search query.
	/// - Parameters:
	///   - column: The desired column key-path.
	///   - matchAttributes: The attributes to apply to matching substrings.
	/// - Returns: The snippet of matching text with matches having the given attributes, or `nil` if this column didn't match the query or snippets were not generated by the search.
	public func snippet(_ column: T.IronbirdColumnKeyPath, matchAttributes: AttributeContainer) -> AttributedString? {
		guard case .generate(_, let prefix, let suffix, _) = snippetMode, let text = snippets?.value(keyPath: column)?.stringValue, text.contains(prefix), text.contains(suffix) else { return nil }
		return self.higlightedText(text, prefix: prefix, suffix: suffix, matchAttributes: matchAttributes)
	}

	private func higlightedText(_ text: String, prefix: String, suffix: String, matchAttributes: AttributeContainer) -> AttributedString {
		var attrString = AttributedString()

		let scanner = Scanner(string: text)
		scanner.charactersToBeSkipped = nil

		while !scanner.isAtEnd {
			if let before = scanner.scanUpToString(prefix) { attrString.append(AttributedString(before)) }

			if scanner.scanString(prefix) == prefix, let highlighted = scanner.scanUpToString(suffix) {
				attrString.append(AttributedString(highlighted, attributes: matchAttributes))
				_ = scanner.scanString(suffix)
			}
		}
		return attrString
	}
}

/// How a full-text-search query should be escaped or processed.
public enum IronbirdFullTextQuerySyntaxMode: Sendable {
	/// The query will be passed directly to SQLite, supporting [the complete FTS5 complete syntax](https://sqlite.org/fts5.html#full_text_query_syntax).
	case allowFullQuerySyntax

	/// All entered text will be passed to SQLite as literal phrases, without supporting [SQLite FTS operators](https://sqlite.org/fts5.html#full_text_query_syntax).
	case escapeQuerySyntax

	/// All entered text will be passed to SQLite as literal phrases, without supporting [SQLite FTS operators](https://sqlite.org/fts5.html#full_text_query_syntax).
	/// The last phrase in a query will be modified to also match any terms that begin with it, so e.g. `"accidental tech pod"` would match `"accidental tech podcast"`.
	case escapeQuerySyntaxAndPrefixMatchLastPhrase
}

fileprivate struct IronbirdFullTextQuerySyntaxPhrase {
	let phrase: String
	let wasQuoted: Bool
}

public extension IronbirdModel {
	typealias SearchResult = IronbirdModelSearchResult<Self>

	/// Consolidate the full-text index into an optimized structure for fastest querying.
	///
	/// This is a heavy operation that may take noticeable time on large indexes.
	static func optimizeFullTextIndex(in database: Ironbird.Database) async throws {
		try await self.optimizeFullTextIndexIsolated(in: database, core: database.core)
	}

	/// Synchronous version of ``optimizeFullTextIndex(in:)``.
	static func optimizeFullTextIndexIsolated(in database: Ironbird.Database, core: isolated Ironbird.Database.Core) throws {
		if Self.fullTextSearchableColumns.isEmpty { return }

		let ftsTable = Ironbird.Table.FullTextIndexSchema.ftsTableName(Self.tableName)
		try core.query("INSERT INTO `\(ftsTable)`(`\(ftsTable)`) VALUES ('optimize')")
		try core.query("PRAGMA wal_checkpoint(TRUNCATE)")
		try core.query("PRAGMA incremental_vacuum(16)")
	}

	/// Search this model's full-text index.
	/// - Parameters:
	///   - database: The database to query.
	///   - matching: The expression to match. For instance, `.match("tech")`
	///   - limit: Return at most this many results. If unspecified or `nil`, all matching results are returned.
	///   - options: Options for this search.
	/// - Returns: The matching set of ``IronbirdModelSearchResult`` objects.
	///
	/// This requires that this model has at least one total column, and all columns referenced in the `matching` argument, specified in ``IronbirdModel/fullTextSearchableColumns``.
	static func fullTextSearch(from database: Ironbird.Database, matching: IronbirdModelColumnExpression<Self>, limit: Int? = nil, options: IronbirdModelSearchOptions<Self> = .init()) async throws -> [Self.SearchResult] {
		try await self.fullTextSearchIsolated(from: database, core: database.core, matching: matching, limit: limit, options: options)
	}

	/// Synchronous version of ``fullTextSearch(from:matching:limit:options:)``.
	static func fullTextSearchIsolated(from database: Ironbird.Database, core: isolated Ironbird.Database.Core, matching: IronbirdModelColumnExpression<Self>, limit: Int? = nil, options: IronbirdModelSearchOptions<Self> = .init()) throws -> [Self.SearchResult] {
		let decoded = DecodedStructuredFTSQuery<Self>(matching: matching, options: options, limit: limit)
		return try decoded.query(in: database, core: core, scoreMultiplier: options.scoreMultiple)
	}

	internal static func fullTextQueryEscape(_ query: String, mode: IronbirdFullTextQuerySyntaxMode) -> String {
		if mode == .allowFullQuerySyntax { return query }

		let tokenCharacters = CharacterSet.whitespacesAndNewlines.inverted
		let phraseDelimters = CharacterSet(charactersIn:
			"\"'“”‘’`«‹»›}\u{201E}\u{201A}\u{201C}\u{201F}\u{2018}\u{201B}\u{201D}\u{2019}\u{275B}\u{275C}\u{275F}\u{275D}\u{275E}\u{276E}\u{276F}\u{2E42}\u{301D}\u{301E}\u{301F}\u{FF02}")
		let scanner = Scanner(string: query)

		var isQuotedPhrase = false
		var currentPhraseWasQuoted = false
		var phrases: [IronbirdFullTextQuerySyntaxPhrase] = []
		var currentPhraseWords: [String] = []

		let endPhrase = {
			let phrase = currentPhraseWords.joined(separator: " ")
			if !phrase.isEmpty {
				phrases.append(IronbirdFullTextQuerySyntaxPhrase(phrase: phrase, wasQuoted: currentPhraseWasQuoted))
			}
			currentPhraseWords.removeAll()
			currentPhraseWasQuoted = false
		}

		while !scanner.isAtEnd {
			let beforeStr = scanner.scanUpToCharacters(from: tokenCharacters)
			if let beforeStr, !beforeStr.isEmpty, beforeStr.rangeOfCharacter(from: phraseDelimters) != nil {
				isQuotedPhrase = !isQuotedPhrase

				if isQuotedPhrase { currentPhraseWasQuoted = true }
				else { endPhrase() }
			}

			if let currentWord = scanner.scanCharacters(from: tokenCharacters), !currentWord.isEmpty {
				currentPhraseWords.append(currentWord)
			}

			if !isQuotedPhrase || scanner.isAtEnd { endPhrase() }
		}

		let escapedQuery = phrases.map { "\"\($0.phrase)\"" }.joined(separator: " ")
		if mode == .escapeQuerySyntaxAndPrefixMatchLastPhrase, let last = phrases.last, !last.wasQuoted {
			return "\(escapedQuery) *"
		} else {
			return escapedQuery
		}
	}
}

fileprivate struct DecodedStructuredFTSQuery<T: IronbirdModel> {
	let query: String
	let arguments: [Sendable]
	let table: Ironbird.Table
	let cacheKey: [Ironbird.Value]?

	let highlightColumnPrefix = "FTSHighlight"
	let snippetColumnPrefix = "FTSSnippet"
	let scoreColumnName = "FTS+Score"
	let fieldNames: [String]
	let options: IronbirdModelSearchOptions<T>

	init(matching: IronbirdModelColumnExpression<T>, options: IronbirdModelSearchOptions<T>, limit: Int?) {
		self.options = options
		self.table = SchemaGenerator.shared.table(for: T.self)

		guard let fullTextIndex = table.fullTextIndex else {
			fatalError("[Ironbird] \(String(describing: T.self)) does not define any fullTextSearchableColumns.")
		}

		for orderBy in options.orderBy {
			guard T.fullTextSearchableColumns[orderBy.column] != nil else {
				let keyPathName = self.table.keyPathToColumnName(keyPath: orderBy.column)
				fatalError("Column \\.$\(keyPathName) in full-text-search order-by clause is not included in `\(self.table.name).fullTextSearchableColumns`. Consider adding it as .filterOnly.")
			}
		}

		let ftsTableName = Ironbird.Table.FullTextIndexSchema.ftsTableName(T.tableName)
		var clauses: [String] = []
		var arguments: [Ironbird.Value] = []

		self.fieldNames = fullTextIndex.sortedFieldNames
		let fieldWeights = self.fieldNames.map { fullTextIndex.fields[$0]?.weight ?? 0.0 }

		var bm25expr = "(-1 * bm25(`\(ftsTableName)`,\(fieldWeights.map { "\($0)" }.joined(separator: ","))))"
		if let scoreMultipleColumn = options.scoreMultipleColumn {
			bm25expr += " * `\(self.table.keyPathToFTSColumnName(keyPath: scoreMultipleColumn))`"
		}

		var columnsToSelect: [String] = [
			"rowid",
			"\(bm25expr) AS `\(scoreColumnName)`",
		]

		if case .generate(let prefix, let suffix) = options.highlights {
			var idx = 0
			for _ in self.fieldNames {
				columnsToSelect.append("highlight(`\(ftsTableName)`, \(idx), ?, ?) AS `\(self.highlightColumnPrefix)+\(idx)`")
				arguments.append(.text(prefix))
				arguments.append(.text(suffix))
				idx += 1
			}
		}

		if case .generate(let contextWords, let prefix, let suffix, let ellipsis) = options.snippets {
			var idx = 0
			for _ in self.fieldNames {
				columnsToSelect.append("snippet(`\(ftsTableName)`, \(idx), ?, ?, ?, \(contextWords)) AS `\(self.snippetColumnPrefix)+\(idx)`")
				arguments.append(.text(prefix))
				arguments.append(.text(suffix))
				arguments.append(.text(ellipsis))
				idx += 1
			}
		}

		let selectClause = "SELECT \(columnsToSelect.joined(separator: ","))"

		let (whereClause, whereArguments) = matching.compile(table: self.table, queryingFullTextIndex: true)
		if let whereClause { clauses.append("WHERE \(whereClause)") }
		arguments.append(contentsOf: whereArguments)

		if !options.orderBy.isEmpty {
			let table = table
			let orderBy = options.orderBy
			clauses.append("ORDER BY \(orderBy.map { $0.orderByClause(table: table) }.joined(separator: ",")) ")
		} else {
			clauses.append("ORDER BY `\(self.scoreColumnName)` DESC")
		}

		if let limit { clauses.append("LIMIT \(limit)") }

		self.query = "\(selectClause) FROM `\(ftsTableName)` \(clauses.joined(separator: " "))"
		self.arguments = arguments

		var cacheKey = [Ironbird.Value.text(self.query)]
		cacheKey.append(contentsOf: arguments)
		self.cacheKey = cacheKey
	}

	func query(in database: Ironbird.Database, core: isolated Ironbird.Database.Core, scoreMultiplier: Double) throws -> [IronbirdModelSearchResult<T>] {
		var results: [IronbirdModelSearchResult<T>] = []
		for row in try T.queryIsolated(in: database, core: core, self.query, arguments: self.arguments) {
			if let result = try result(database: database, core: core, ftsRow: row, scoreMultiplier: scoreMultiplier) {
				results.append(result)
			}
		}
		return results
	}

	private func result(database: Ironbird.Database, core: isolated Ironbird.Database.Core, ftsRow: Ironbird.ModelRow<T>, scoreMultiplier: Double) throws -> IronbirdModelSearchResult<T>? {
		guard let rowid = ftsRow["rowid"], let score = ftsRow[scoreColumnName] else {
			fatalError("Unexpected result row format from FTS query on \(String(describing: T.self)) (missing rowid or score)")
		}

		var idx = 0
		var highlightRow: [String: Ironbird.Value] = [:]
		var snippetRow: [String: Ironbird.Value] = [:]
		for fieldName in self.fieldNames {
			if let highlight = ftsRow["\(highlightColumnPrefix)+\(idx)"] {
				highlightRow[fieldName] = highlight
			}

			if let snippet = ftsRow["\(snippetColumnPrefix)+\(idx)"] {
				snippetRow[fieldName] = snippet
			}
			idx += 1
		}

		let preloadedInstance = try options.preloadInstances ? T.readIsolated(from: database, core: core, sqlWhere: "rowid = ?", arguments: [rowid]).first : nil
		return IronbirdModelSearchResult<T>(highlights: .init(highlightRow, table: self.table), highlightMode: self.options.highlights, snippets: .init(snippetRow, table: self.table), snippetMode: self.options.snippets, rowid: rowid, score: (score.doubleValue ?? 0) * scoreMultiplier, preloadedInstance: preloadedInstance)
	}
}

extension Ironbird.Table {
	struct FullTextIndexSchema: Equatable, Hashable {
		static let defaultTokenizer = "porter unicode61 remove_diacritics 2"

		func hash(into hasher: inout Hasher) {
			hasher.combine(self.contentTableName)
			hasher.combine(self.fields)
			hasher.combine(self.tokenizer)
		}

		let contentTableName: String
		let fields: [String: IronbirdModelFullTextSearchableColumn]
		let tokenizer: String

		var sortedFieldNames: [String] { self.fields.keys.sorted { $0 < $1 } }

		static func ftsTableName(_ contentTableName: String) -> String { "\(contentTableName)+FTS" }
		static func insertTriggerName(_ contentTableName: String) -> String { "\(contentTableName)+FTSInsert" }
		static func updateTriggerName(_ contentTableName: String) -> String { "\(contentTableName)+FTSUpdate" }
		static func deleteTriggerName(_ contentTableName: String) -> String { "\(contentTableName)+FTSDelete" }

		var ftsTableDefinition: String {
			let fieldDefinitions = self.sortedFieldNames.map {
				self.fields[$0]!.indexed ? "`\($0)`" : "`\($0)` UNINDEXED"
			}

			return "CREATE VIRTUAL TABLE `\(Self.ftsTableName(self.contentTableName))` USING fts5(\(fieldDefinitions.joined(separator: ",")),content=`\(self.contentTableName)`,tokenize='\(self.tokenizer)')"
		}

		static func ftsTableExists(core: isolated Ironbird.Database.Core, contentTableName: String) throws -> Bool {
			!(try core.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", arguments: [self.ftsTableName(contentTableName)])).isEmpty
		}

		func recreateTriggers(core: isolated Ironbird.Database.Core) throws {
			let insertTriggerName = Self.insertTriggerName(self.contentTableName)
			let updateTriggerName = Self.updateTriggerName(self.contentTableName)
			let deleteTriggerName = Self.deleteTriggerName(self.contentTableName)

			try core.query("DROP TRIGGER IF EXISTS `\(insertTriggerName)`")
			try core.query("DROP TRIGGER IF EXISTS `\(updateTriggerName)`")
			try core.query("DROP TRIGGER IF EXISTS `\(deleteTriggerName)`")

			let ftsTableName = Self.ftsTableName(self.contentTableName)

			let rawFieldNames = self.sortedFieldNames
			let fieldNames = rawFieldNames.map { "`\($0)`" }.joined(separator: ",")
			let oldFieldNames = rawFieldNames.map { "OLD.`\($0)`" }.joined(separator: ",")
			let newFieldNames = rawFieldNames.map { "NEW.`\($0)`" }.joined(separator: ",")

			try core.query("""
			CREATE TRIGGER `\(insertTriggerName)` AFTER INSERT ON `\(self.contentTableName)` BEGIN
			    INSERT INTO `\(ftsTableName)`(rowid,\(fieldNames)) VALUES (NEW.rowid,\(newFieldNames));
			END
			""")

			try core.query("""
			CREATE TRIGGER `\(updateTriggerName)` AFTER UPDATE OF \(fieldNames) ON `\(self.contentTableName)` BEGIN
			    INSERT INTO `\(ftsTableName)`(`\(ftsTableName)`,rowid,\(fieldNames)) VALUES ('delete',OLD.rowid,\(oldFieldNames));
			    INSERT INTO `\(ftsTableName)`(rowid,\(fieldNames)) VALUES (NEW.rowid,\(newFieldNames));
			END
			""")

			try core.query("""
			CREATE TRIGGER `\(deleteTriggerName)` AFTER DELETE ON `\(self.contentTableName)` BEGIN
			    INSERT INTO `\(ftsTableName)`(`\(ftsTableName)`,rowid,\(fieldNames)) VALUES ('delete',OLD.rowid,\(oldFieldNames));
			END
			""")
		}

		func rebuild(core: isolated Ironbird.Database.Core) throws {
			let ftsTableName = Self.ftsTableName(self.contentTableName)
			try core.query("DROP TABLE IF EXISTS `\(ftsTableName)`")
			try core.query(self.ftsTableDefinition)
			try self.recreateTriggers(core: core)
			try core.query("INSERT INTO `\(ftsTableName)`(`\(ftsTableName)`) VALUES('rebuild')")
		}

		func needsRebuild(core: isolated Ironbird.Database.Core) throws -> Bool {
			let ftsTableName = Self.ftsTableName(self.contentTableName)
			let createdWithSQL = try core.query("SELECT sql FROM sqlite_master WHERE name = '\(ftsTableName)'").first?["sql"]?.stringValue ?? ""
			if createdWithSQL != self.ftsTableDefinition { return true }

			let triggerNames = Set(try core.query("SELECT name FROM sqlite_master WHERE type = 'trigger'").compactMap {
				if let name = $0["name"]?.stringValue, name.hasPrefix(contentTableName) { return name }
				return nil
			})

			return !triggerNames.contains(Self.insertTriggerName(self.contentTableName)) ||
				!triggerNames.contains(Self.updateTriggerName(self.contentTableName)) ||
				!triggerNames.contains(Self.deleteTriggerName(self.contentTableName))
		}

		init(contentTableName: String, fields: [String: IronbirdModelFullTextSearchableColumn], tokenizer: String? = nil) {
			guard sqlite3_compileoption_used("ENABLE_FTS5") != 0 else { fatalError("[Ironbird] SQLite was compiled without FTS5 support, but a full-text index is specified on table `\(contentTableName)`") }
			guard !fields.isEmpty else { fatalError("No columns specified") }
			self.contentTableName = contentTableName
			self.fields = fields
			self.tokenizer = tokenizer ?? Self.defaultTokenizer
		}
	}
}
