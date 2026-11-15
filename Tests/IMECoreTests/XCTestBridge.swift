// FIX(CLT): 自动生成 —— 把每个 XCTestCase 测试方法注册为 swift-testing 的 @Test（每个用例新建实例，串行执行）。
// 由 scripts/gen_xctest_bridge.py 生成；装了 Xcode（canImport(XCTest)）时不启用。
#if !canImport(XCTest)
import Testing

@Suite("AnchorChainTests", .serialized) struct AnchorChainTests_Bridge {
    @Test func testSelectionWinsAndShortCircuits() async throws { AnchorChainTests().testSelectionWinsAndShortCircuits() }
    @Test func testCaretWhenNoSelection() async throws { AnchorChainTests().testCaretWhenNoSelection() }
    @Test func testFieldWhenNoCaretAndTallFieldRejected() async throws { AnchorChainTests().testFieldWhenNoCaretAndTallFieldRejected() }
    @Test func testIMKCaretUsedWhenAXHasNothing() async throws { AnchorChainTests().testIMKCaretUsedWhenAXHasNothing() }
    @Test func testUntrustedSkipsAllAXAndUsesMouse() async throws { AnchorChainTests().testUntrustedSkipsAllAXAndUsesMouse() }
    @Test func testTrustCheckedEveryTimeNotCached() async throws { AnchorChainTests().testTrustCheckedEveryTimeNotCached() }
    @Test func testUnusableRectsIgnored() async throws { AnchorChainTests().testUnusableRectsIgnored() }
    @Test func testWindowWhenMouseUnavailable() async throws { AnchorChainTests().testWindowWhenMouseUnavailable() }
    @Test func testFallbackWhenNothing() async throws { AnchorChainTests().testFallbackWhenNothing() }
    @Test func testNoPidMeansNoAX() async throws { AnchorChainTests().testNoPidMeansNoAX() }
    @Test func testMouseBelowRight() async throws { AnchorChainTests().testMouseBelowRight() }
    @Test func testMouseNearBottomRightIsClampedAndFlipped() async throws { AnchorChainTests().testMouseNearBottomRightIsClampedAndFlipped() }
    @Test func testWindowLowerThirdCentered() async throws { AnchorChainTests().testWindowLowerThirdCentered() }
    @Test func testWindowPanelClampedToScreen() async throws { AnchorChainTests().testWindowPanelClampedToScreen() }
    @Test func testSelectionPlacedBelowSelection() async throws { AnchorChainTests().testSelectionPlacedBelowSelection() }
    @Test func testDescribeHasNoUserText() async throws { AnchorChainTests().testDescribeHasNoUserText() }
}

@Suite("PanelPlacementTests", .serialized) struct PanelPlacementTests_Bridge {
    @Test func testBelowCaretByDefault() async throws { PanelPlacementTests().testBelowCaretByDefault() }
    @Test func testAboveWhenNearScreenBottom() async throws { PanelPlacementTests().testAboveWhenNearScreenBottom() }
    @Test func testClampedToRightEdge() async throws { PanelPlacementTests().testClampedToRightEdge() }
    @Test func testClampedToLeftEdge() async throws { PanelPlacementTests().testClampedToLeftEdge() }
    @Test func testTallPanelPicksLargerSideAndStaysOnScreen() async throws { PanelPlacementTests().testTallPanelPicksLargerSideAndStaysOnScreen() }
    @Test func testSecondaryScreenWithOffsetOrigin() async throws { PanelPlacementTests().testSecondaryScreenWithOffsetOrigin() }
    @Test func testFieldRectAsCaret() async throws { PanelPlacementTests().testFieldRectAsCaret() }
    @Test func testQuartzToCocoaConversion() async throws { PanelPlacementTests().testQuartzToCocoaConversion() }
    @Test func testUnusableCaretRejected() async throws { PanelPlacementTests().testUnusableCaretRejected() }
}

@Suite("InsertionPlannerTests", .serialized) struct InsertionPlannerTests_Bridge {
    @Test func testStrategyMatrix() async throws { InsertionPlannerTests().testStrategyMatrix() }
    @Test func testHintsMentionAutoInsert() async throws { InsertionPlannerTests().testHintsMentionAutoInsert() }
}

@Suite("AutoInserterTests", .serialized) struct AutoInserterTests_Bridge {
    @Test @MainActor func testClientInsertDoesNotTouchClipboardOrKeys() async throws { await AutoInserterTests().testClientInsertDoesNotTouchClipboardOrKeys() }
    @Test @MainActor func testClientUnavailableFallsBackToPasteWhenTrusted() async throws { await AutoInserterTests().testClientUnavailableFallsBackToPasteWhenTrusted() }
    @Test @MainActor func testClientUnavailableFallsBackToCopyOnlyWhenUntrusted() async throws { await AutoInserterTests().testClientUnavailableFallsBackToCopyOnlyWhenUntrusted() }
    @Test @MainActor func testPasteSendsOnlyCommandVAndRestoresClipboard() async throws { await AutoInserterTests().testPasteSendsOnlyCommandVAndRestoresClipboard() }
    @Test @MainActor func testDoesNotOverwriteIfUserCopiedMeanwhile() async throws { await AutoInserterTests().testDoesNotOverwriteIfUserCopiedMeanwhile() }
    @Test @MainActor func testCopyOnlyLeavesEnglishOnClipboard() async throws { await AutoInserterTests().testCopyOnlyLeavesEnglishOnClipboard() }
    @Test @MainActor func testNoRetriggerFromPasteOrRestore() async throws { await AutoInserterTests().testNoRetriggerFromPasteOrRestore() }
    @Test @MainActor func testCopyOnlyNoRetrigger() async throws { await AutoInserterTests().testCopyOnlyNoRetrigger() }
}

@Suite("ClipboardFilterTests", .serialized) struct ClipboardFilterTests_Bridge {
    @Test func testEnglishSentenceTriggers() async throws { ClipboardFilterTests().testEnglishSentenceTriggers() }
    @Test func testChineseAndJapaneseIgnored() async throws { ClipboardFilterTests().testChineseAndJapaneseIgnored() }
    @Test func testSensitiveTypesIgnored() async throws { ClipboardFilterTests().testSensitiveTypesIgnored() }
    @Test func testOwnPrivateTypeIgnored() async throws { ClipboardFilterTests().testOwnPrivateTypeIgnored() }
    @Test func testURLsAndEmailsIgnored() async throws { ClipboardFilterTests().testURLsAndEmailsIgnored() }
    @Test func testFilePathsIgnored() async throws { ClipboardFilterTests().testFilePathsIgnored() }
    @Test func testNumbersIgnored() async throws { ClipboardFilterTests().testNumbersIgnored() }
    @Test func testCodeIgnored() async throws { ClipboardFilterTests().testCodeIgnored() }
    @Test func testTooShortAndTooLong() async throws { ClipboardFilterTests().testTooShortAndTooLong() }
    @Test func testDuplicateOfLastTextIgnored() async throws { ClipboardFilterTests().testDuplicateOfLastTextIgnored() }
    @Test func testFilterIsFast() async throws { ClipboardFilterTests().testFilterIsFast() }
}

@Suite("ClipboardWatcherTests", .serialized) struct ClipboardWatcherTests_Bridge {
    @Test @MainActor func testExistingClipboardAtStartupDoesNotTrigger() async throws { ClipboardWatcherTests().testExistingClipboardAtStartupDoesNotTrigger() }
    @Test @MainActor func testNewEnglishCopyTriggersOnce() async throws { ClipboardWatcherTests().testNewEnglishCopyTriggersOnce() }
    @Test @MainActor func testUnchangedPollDoesNotReadPasteboard() async throws { ClipboardWatcherTests().testUnchangedPollDoesNotReadPasteboard() }
    @Test @MainActor func testOwnWriteIgnoredByChangeCount() async throws { ClipboardWatcherTests().testOwnWriteIgnoredByChangeCount() }
    @Test @MainActor func testOwnWriteIgnoredByPrivateType() async throws { ClipboardWatcherTests().testOwnWriteIgnoredByPrivateType() }
    @Test @MainActor func testToggleOffDoesNothingAndReenableDoesNotReplay() async throws { ClipboardWatcherTests().testToggleOffDoesNothingAndReenableDoesNotReplay() }
    @Test @MainActor func testPauseOneHour() async throws { ClipboardWatcherTests().testPauseOneHour() }
    @Test @MainActor func testBusyPanelNotInterrupted() async throws { ClipboardWatcherTests().testBusyPanelNotInterrupted() }
    @Test @MainActor func testSensitiveCopyIgnored() async throws { ClipboardWatcherTests().testSensitiveCopyIgnored() }
    @Test @MainActor func testPollingCostIsNegligible() async throws { ClipboardWatcherTests().testPollingCostIsNegligible() }
}

@Suite("ReadingReplyFlowTests", .serialized) struct ReadingReplyFlowTests_Bridge {
    @Test @MainActor func testReturnStartsReplyEscapeCloses() async throws { ReadingReplyFlowTests().testReturnStartsReplyEscapeCloses() }
    @Test @MainActor func testFullReadReplyCopyFlow() async throws { await ReadingReplyFlowTests().testFullReadReplyCopyFlow() }
}

@Suite("CompositionBufferTests", .serialized) struct CompositionBufferTests_Bridge {
    @Test func testOnlyLettersStartComposition() async throws { CompositionBufferTests().testOnlyLettersStartComposition() }
    @Test func testSentenceAccumulatesWithSpacesAndPunctuation() async throws { CompositionBufferTests().testSentenceAccumulatesWithSpacesAndPunctuation() }
    @Test func testCommitCancelKeys() async throws { CompositionBufferTests().testCommitCancelKeys() }
    @Test func testDelete() async throws { CompositionBufferTests().testDelete() }
    @Test func testModifiedAndOtherKeys() async throws { CompositionBufferTests().testModifiedAndOtherKeys() }
}

@Suite("GlossaryCSVTests", .serialized) struct GlossaryCSVTests_Bridge {
    @Test func testQuotesCommasNewlinesAndBOM() async throws { GlossaryCSVTests().testQuotesCommasNewlinesAndBOM() }
    @Test func testTSVAutoDetectAndExplicit() async throws { GlossaryCSVTests().testTSVAutoDetectAndExplicit() }
    @Test func testFormatRoundTripWithBOMAndCRLF() async throws { GlossaryCSVTests().testFormatRoundTripWithBOMAndCRLF() }
    @Test func testBuiltInCSVParsingVariantsAndFlags() async throws { GlossaryCSVTests().testBuiltInCSVParsingVariantsAndFlags() }
    @Test func testXLSXSheetParsing() async throws { GlossaryCSVTests().testXLSXSheetParsing() }
}

@Suite("GlossaryMatchTests", .serialized) struct GlossaryMatchTests_Bridge {
    @Test func testChineseLeftmostLongest() async throws { GlossaryMatchTests().testChineseLeftmostLongest() }
    @Test func testEnglishWholeWordCaseInsensitiveAndPlural() async throws { GlossaryMatchTests().testEnglishWholeWordCaseInsensitiveAndPlural() }
    @Test func testEnglishMultiWordLongestWins() async throws { GlossaryMatchTests().testEnglishMultiWordLongestWins() }
    @Test func testAcronymsAreCaseSensitiveAndKept() async throws { GlossaryMatchTests().testAcronymsAreCaseSensitiveAndKept() }
    @Test func testIsAcronym() async throws { GlossaryMatchTests().testIsAcronym() }
    @Test func testStoplistAndSingleCharSkippedForBuiltIn() async throws { GlossaryMatchTests().testStoplistAndSingleCharSkippedForBuiltIn() }
    @Test func testDirectionFlags() async throws { GlossaryMatchTests().testDirectionFlags() }
    @Test func testDomainToggleAndMaster() async throws { GlossaryMatchTests().testDomainToggleAndMaster() }
    @Test func testUserEntriesWinOverBuiltIn() async throws { GlossaryMatchTests().testUserEntriesWinOverBuiltIn() }
}

@Suite("TermPlanTests", .serialized) struct TermPlanTests_Bridge {
    @Test func testInjectionZhToEn() async throws { try TermPlanTests().testInjectionZhToEn() }
    @Test func testInjectionPadsLatinNeighbours() async throws { try TermPlanTests().testInjectionPadsLatinNeighbours() }
    @Test func testAdjacentTermsAreSpacedInBothModes() async throws { try TermPlanTests().testAdjacentTermsAreSpacedInBothModes() }
    @Test func testAcceptInjectedVerifiesTerms() async throws { try TermPlanTests().testAcceptInjectedVerifiesTerms() }
    @Test func testPlaceholderRoundTripAndMangledRecovery() async throws { try TermPlanTests().testPlaceholderRoundTripAndMangledRecovery() }
    @Test func testSingleTermSkipsEngine() async throws { try TermPlanTests().testSingleTermSkipsEngine() }
    @Test func testEnToZhKeepsAcronymsAndInjectsChinese() async throws { try TermPlanTests().testEnToZhKeepsAcronymsAndInjectsChinese() }
    @Test func testArticlesAndSentenceCapitalization() async throws { try TermPlanTests().testArticlesAndSentenceCapitalization() }
}

@Suite("GlossaryServiceTests", .serialized) struct GlossaryServiceTests_Bridge {
    @Test func testServiceInjectsTermsAndKeepsThem() async throws { try await GlossaryServiceTests().testServiceInjectsTermsAndKeepsThem() }
    @Test func testServiceFallsBackToPlaceholdersWhenTermLost() async throws { try await GlossaryServiceTests().testServiceFallsBackToPlaceholdersWhenTermLost() }
    @Test func testSingleTermNeedsNoEngine() async throws { try await GlossaryServiceTests().testSingleTermNeedsNoEngine() }
    @Test func testEnToZhDirection() async throws { try await GlossaryServiceTests().testEnToZhDirection() }
    @Test func testCacheClearedWhenGlossaryChanges() async throws { try await GlossaryServiceTests().testCacheClearedWhenGlossaryChanges() }
}

@Suite("UserGlossaryTests", .serialized) struct UserGlossaryTests_Bridge {
    @Test func testTemplateCreatedWithBOMAndHeader() async throws { try UserGlossaryTests().testTemplateCreatedWithBOMAndHeader() }
    @Test func testRowsHeaderDetection() async throws { UserGlossaryTests().testRowsHeaderDetection() }
    @Test func testCorrectionUpsertBothLanguages() async throws { try UserGlossaryTests().testCorrectionUpsertBothLanguages() }
    @Test func testMergeImportAddsAndUpdates() async throws { try UserGlossaryTests().testMergeImportAddsAndUpdates() }
    @Test func testUserVariantsSplitByBar() async throws { UserGlossaryTests().testUserVariantsSplitByBar() }
    @Test func testHotReloadViaFileWatcher() async throws { try await UserGlossaryTests().testHotReloadViaFileWatcher() }
    @Test func testCorrectionPrefill() async throws { UserGlossaryTests().testCorrectionPrefill() }
}

@Suite("BuiltInGlossaryTests", .serialized) struct BuiltInGlossaryTests_Bridge {
    @Test func testBuiltInGlossariesLoadWithExpectedSizes() async throws { BuiltInGlossaryTests().testBuiltInGlossariesLoadWithExpectedSizes() }
    @Test func testNoConflictsAndNoSingleCharacterOrStoplistedKeys() async throws { BuiltInGlossaryTests().testNoConflictsAndNoSingleCharacterOrStoplistedKeys() }
    @Test func testRealGlossaryFixesKnownMistranslations() async throws { BuiltInGlossaryTests().testRealGlossaryFixesKnownMistranslations() }
    @Test func testLookupIsFarBelowOneMillisecond() async throws { BuiltInGlossaryTests().testLookupIsFarBelowOneMillisecond() }
}

@Suite("LanguageDetectorTests", .serialized) struct LanguageDetectorTests_Bridge {
    @Test func testChinese() async throws { LanguageDetectorTests().testChinese() }
    @Test func testEnglish() async throws { LanguageDetectorTests().testEnglish() }
    @Test func testMixedTextFollowsDominantScript() async throws { LanguageDetectorTests().testMixedTextFollowsDominantScript() }
    @Test func testUnknown() async throws { LanguageDetectorTests().testUnknown() }
}

@Suite("LatencyMonitorTests", .serialized) struct LatencyMonitorTests_Bridge {
    @Test func testPercentiles() async throws { LatencyMonitorTests().testPercentiles() }
    @Test func testRingKeepsOnlyRecentWindowButCountsAll() async throws { LatencyMonitorTests().testRingKeepsOnlyRecentWindowButCountsAll() }
    @Test func testBudgetBreachNotifiesSinkAndCounts() async throws { LatencyMonitorTests().testBudgetBreachNotifiesSinkAndCounts() }
    @Test func testMetricWithoutBudgetNeverFlagged() async throws { LatencyMonitorTests().testMetricWithoutBudgetNeverFlagged() }
    @Test func testPeriodicSummary() async throws { LatencyMonitorTests().testPeriodicSummary() }
    @Test func testMeasureReturnsValueAndRecords() async throws { LatencyMonitorTests().testMeasureReturnsValueAndRecords() }
    @Test func testRecordIsThreadSafe() async throws { await LatencyMonitorTests().testRecordIsThreadSafe() }
    @Test func testDebounceSettingIsClamped() async throws { LatencyMonitorTests().testDebounceSettingIsClamped() }
}

@Suite("InputBoxSizerTests", .serialized) struct InputBoxSizerTests_Bridge {
    @Test func testThresholdIs35ChineseCharacters() async throws { InputBoxSizerTests().testThresholdIs35ChineseCharacters() }
    @Test func testExactly35ChineseCharactersDoesNotWrap() async throws { InputBoxSizerTests().testExactly35ChineseCharactersDoesNotWrap() }
    @Test func test36ChineseCharactersWrapsAndGrowsVertically() async throws { InputBoxSizerTests().test36ChineseCharactersWrapsAndGrowsVertically() }
    @Test func testWidthGrowsWithTextBeforeWrapping() async throws { InputBoxSizerTests().testWidthGrowsWithTextBeforeWrapping() }
    @Test func testShortAndEmptyTextUseMinimumWidth() async throws { InputBoxSizerTests().testShortAndEmptyTextUseMinimumWidth() }
    @Test func testHeightGrowsWithMoreLinesAndIsCapped() async throws { InputBoxSizerTests().testHeightGrowsWithMoreLinesAndIsCapped() }
    @Test func testEnglishUsesSameWidthThreshold() async throws { InputBoxSizerTests().testEnglishUsesSameWidthThreshold() }
    @Test func testFloatingPointToleranceAtThreshold() async throws { InputBoxSizerTests().testFloatingPointToleranceAtThreshold() }
}

@Suite("PasteCompositionTests", .serialized) struct PasteCompositionTests_Bridge {
    @Test func testPasteEnglishIntoEmptyStartsComposition() async throws { PasteCompositionTests().testPasteEnglishIntoEmptyStartsComposition() }
    @Test func testPasteAppendsWhileComposing() async throws { PasteCompositionTests().testPasteAppendsWhileComposing() }
    @Test func testPasteChineseIntoEmptyPassesThrough() async throws { PasteCompositionTests().testPasteChineseIntoEmptyPassesThrough() }
    @Test func testPasteNonTextIntoEmptyPassesThrough() async throws { PasteCompositionTests().testPasteNonTextIntoEmptyPassesThrough() }
    @Test func testPasteNormalizesNewlinesAndSpaces() async throws { PasteCompositionTests().testPasteNormalizesNewlinesAndSpaces() }
    @Test func testTooLongPasteIsNotTakenOver() async throws { PasteCompositionTests().testTooLongPasteIsNotTakenOver() }
    @Test func testAppendIsCappedAtMaxLength() async throws { PasteCompositionTests().testAppendIsCappedAtMaxLength() }
    @Test func testPasteHandlingIsFast() async throws { PasteCompositionTests().testPasteHandlingIsFast() }
    @Test func testPastedTextTriggersTranslation() async throws { await PasteCompositionTests().testPastedTextTriggersTranslation() }
}

@Suite("TranslationCopierTests", .serialized) struct TranslationCopierTests_Bridge {
    @Test @MainActor func testEnterCopiesReadyEnglishTranslation() async throws { await TranslationCopierTests().testEnterCopiesReadyEnglishTranslation() }
    @Test @MainActor func testEnterWaitsForPendingTranslation() async throws { await TranslationCopierTests().testEnterWaitsForPendingTranslation() }
    @Test @MainActor func testEnterBeforeCoordinatorSawTextStillCopies() async throws { await TranslationCopierTests().testEnterBeforeCoordinatorSawTextStillCopies() }
    @Test @MainActor func testEnterDoesNotBlockMainThread() async throws { await TranslationCopierTests().testEnterDoesNotBlockMainThread() }
    @Test @MainActor func testEmptyInputCopiesNothing() async throws { await TranslationCopierTests().testEmptyInputCopiesNothing() }
    @Test @MainActor func testFailedTranslationCopiesNothing() async throws { await TranslationCopierTests().testFailedTranslationCopiesNothing() }
    @Test @MainActor func testSupersededWhenInputChangesWhileWaiting() async throws { try await TranslationCopierTests().testSupersededWhenInputChangesWhileWaiting() }
    @Test @MainActor func testEnglishInputCopiesChineseTranslation() async throws { await TranslationCopierTests().testEnglishInputCopiesChineseTranslation() }
    @Test @MainActor func testCopyNeverSpeaks() async throws { await TranslationCopierTests().testCopyNeverSpeaks() }
}

@Suite("InputSourceSwitcherTests", .serialized) struct InputSourceSwitcherTests_Bridge {
    @Test @MainActor func testSwitchesToEnabledSimplifiedPinyinAndRestores() async throws { InputSourceSwitcherTests().testSwitchesToEnabledSimplifiedPinyinAndRestores() }
    @Test @MainActor func testPrefersAppleSimplifiedPinyin() async throws { InputSourceSwitcherTests().testPrefersAppleSimplifiedPinyin() }
    @Test @MainActor func testFallsBackToOtherSimplifiedPinyinButNeverTraditional() async throws { InputSourceSwitcherTests().testFallsBackToOtherSimplifiedPinyinButNeverTraditional() }
    @Test @MainActor func testIgnoresDisabledOrNonSelectableSources() async throws { InputSourceSwitcherTests().testIgnoresDisabledOrNonSelectableSources() }
    @Test @MainActor func testNoPinyinShowsHintAndChangesNothing() async throws { InputSourceSwitcherTests().testNoPinyinShowsHintAndChangesNothing() }
    @Test @MainActor func testAlreadyPinyinDoesNotSwitchOrRestore() async throws { InputSourceSwitcherTests().testAlreadyPinyinDoesNotSwitchOrRestore() }
    @Test @MainActor func testSelectFailureIsReportedAndNotRestored() async throws { InputSourceSwitcherTests().testSelectFailureIsReportedAndNotRestored() }
    @Test @MainActor func testRepeatedActivateKeepsOriginalSource() async throws { InputSourceSwitcherTests().testRepeatedActivateKeepsOriginalSource() }
    @Test @MainActor func testReassertOnlyWhenSourceDrifted() async throws { InputSourceSwitcherTests().testReassertOnlyWhenSourceDrifted() }
    @Test @MainActor func testRestoreSkippedWhenAlreadyBackOnPreviousSource() async throws { InputSourceSwitcherTests().testRestoreSkippedWhenAlreadyBackOnPreviousSource() }
}

@Suite("PanelLayoutRegressionTests", .serialized) struct PanelLayoutRegressionTests_Bridge {
    @Test @MainActor func testOneLine() async throws { PanelLayoutRegressionTests().testOneLine() }
    @Test @MainActor func testTwoLines() async throws { PanelLayoutRegressionTests().testTwoLines() }
    @Test @MainActor func testThreeLines() async throws { PanelLayoutRegressionTests().testThreeLines() }
    @Test @MainActor func testTenLines() async throws { PanelLayoutRegressionTests().testTenLines() }
    @Test @MainActor func test35CharsStaySingleLineInRealTextView() async throws { PanelLayoutRegressionTests().test35CharsStaySingleLineInRealTextView() }
    @Test @MainActor func testMixedChineseEnglishAndPinyinMarkedText() async throws { PanelLayoutRegressionTests().testMixedChineseEnglishAndPinyinMarkedText() }
    @Test @MainActor func testEmptyTextIsOneLineHigh() async throws { PanelLayoutRegressionTests().testEmptyTextIsOneLineHigh() }
    @Test @MainActor func testBeyondMaxLinesCapsHeightAndAllowsScrolling() async throws { PanelLayoutRegressionTests().testBeyondMaxLinesCapsHeightAndAllowsScrolling() }
}

@Suite("PanelSubmitPolicyTests", .serialized) struct PanelSubmitPolicyTests_Bridge {
    @Test func testKeyMapping() async throws { PanelSubmitPolicyTests().testKeyMapping() }
    @Test func testCopyThenCloseAfterHalfSecondByDefault() async throws { PanelSubmitPolicyTests().testCopyThenCloseAfterHalfSecondByDefault() }
    @Test func testCopyStaysOpenWhenAutoCloseDisabled() async throws { PanelSubmitPolicyTests().testCopyStaysOpenWhenAutoCloseDisabled() }
    @Test func testShiftOptionReturnClearsAndStays() async throws { PanelSubmitPolicyTests().testShiftOptionReturnClearsAndStays() }
    @Test func testFailureNeverClosesAndShowsError() async throws { PanelSubmitPolicyTests().testFailureNeverClosesAndShowsError() }
    @Test func testEmptyOrSupersededDoesNothing() async throws { PanelSubmitPolicyTests().testEmptyOrSupersededDoesNothing() }
    @Test func testHintTextReflectsSetting() async throws { PanelSubmitPolicyTests().testHintTextReflectsSetting() }
    @Test func testCloseAfterCopyDefaultsOn() async throws { PanelSubmitPolicyTests().testCloseAfterCopyDefaultsOn() }
    @Test func testPendingTranslationCopiedThenClose() async throws { await PanelSubmitPolicyTests().testPendingTranslationCopiedThenClose() }
}

@Suite("PerformanceTests", .serialized) struct PerformanceTests_Bridge {
    @Test @MainActor func testKeystrokeUnder5msWithSlowAsyncProvider() async throws { try await PerformanceTests().testKeystrokeUnder5msWithSlowAsyncProvider() }
    @Test @MainActor func testKeystrokeUnder5msWithThreadBlockingProvider() async throws { try await PerformanceTests().testKeystrokeUnder5msWithThreadBlockingProvider() }
    @Test @MainActor func testDebounceCollapsesBurstIntoSingleCall() async throws { try await PerformanceTests().testDebounceCollapsesBurstIntoSingleCall() }
    @Test @MainActor func testStaleResultNeverOverwritesNewer() async throws { try await PerformanceTests().testStaleResultNeverOverwritesNewer() }
    @Test @MainActor func testCancelledRequestIsNotPublishedAfterReset() async throws { try await PerformanceTests().testCancelledRequestIsNotPublishedAfterReset() }
    @Test @MainActor func testCacheHitIsSynchronousAndSkipsProvider() async throws { try await PerformanceTests().testCacheHitIsSynchronousAndSkipsProvider() }
    @Test @MainActor func testTranslationCacheLRUEvictsOldest() async throws { PerformanceTests().testTranslationCacheLRUEvictsOldest() }
    @Test @MainActor func testCacheLookupIsFast() async throws { PerformanceTests().testCacheLookupIsFast() }
    @Test @MainActor func testCompositionBufferThroughput() async throws { PerformanceTests().testCompositionBufferThroughput() }
    @Test @MainActor func testLanguageDetectorOnLongTextIsFast() async throws { PerformanceTests().testLanguageDetectorOnLongTextIsFast() }
}

@Suite("PronunciationTests", .serialized) struct PronunciationTests_Bridge {
    @Test @MainActor func testNoAutoSpeakWhenTranslationCompletes() async throws { await PronunciationTests().testNoAutoSpeakWhenTranslationCompletes() }
    @Test @MainActor func testNoAutoSpeakAcrossManyUpdatesAndReset() async throws { await PronunciationTests().testNoAutoSpeakAcrossManyUpdatesAndReset() }
    @Test @MainActor func testSpeaksOnlyWhenButtonTapped() async throws { await PronunciationTests().testSpeaksOnlyWhenButtonTapped() }
    @Test @MainActor func testEnglishSourcePronouncesOriginalOnlyWhenTapped() async throws { await PronunciationTests().testEnglishSourcePronouncesOriginalOnlyWhenTapped() }
    @Test @MainActor func testNoAutoSpeakForEnglishSourceAcrossUpdatesAndReset() async throws { await PronunciationTests().testNoAutoSpeakForEnglishSourceAcrossUpdatesAndReset() }
    @Test @MainActor func testChineseIsNeverSpokenInEitherDirection() async throws { await PronunciationTests().testChineseIsNeverSpokenInEitherDirection() }
    @Test @MainActor func testPronunciationTextPerDirection() async throws { await PronunciationTests().testPronunciationTextPerDirection() }
    @Test @MainActor func testEnglishSourceTapIgnoredWhileLoading() async throws { await PronunciationTests().testEnglishSourceTapIgnoredWhileLoading() }
    @Test @MainActor func testTapIgnoredWhenIdleOrLoadingOrFailed() async throws { await PronunciationTests().testTapIgnoredWhenIdleOrLoadingOrFailed() }
    @Test @MainActor func testUtteranceUsesAmericanEnglish() async throws { try PronunciationTests().testUtteranceUsesAmericanEnglish() }
    @Test @MainActor func testSourceGuardOnlyCoordinatorCallsSpeak() async throws { try PronunciationTests().testSourceGuardOnlyCoordinatorCallsSpeak() }
}

@Suite("InputBoxFinderTests", .serialized) struct InputBoxFinderTests_Bridge {
    @Test func testSkipsSearchSecureDisabledAndNonEditable() async throws { InputBoxFinderTests().testSkipsSearchSecureDisabledAndNonEditable() }
    @Test func testPicksBottomWideMessageBox() async throws { InputBoxFinderTests().testPicksBottomWideMessageBox() }
    @Test func testBottomBeatsTopWhenNoHints() async throws { InputBoxFinderTests().testBottomBeatsTopWhenNoHints() }
    @Test func testMessagePlaceholderWinsOverSlightlyLowerField() async throws { InputBoxFinderTests().testMessagePlaceholderWinsOverSlightlyLowerField() }
    @Test func testHugeEditorPenalized() async throws { InputBoxFinderTests().testHugeEditorPenalized() }
    @Test func testTinyOrOffWindowRejected() async throws { InputBoxFinderTests().testTinyOrOffWindowRejected() }
    @Test func testChineseSearchPlaceholderRejected() async throws { InputBoxFinderTests().testChineseSearchPlaceholderRejected() }
}

@Suite("ReplyInserterTests", .serialized) struct ReplyInserterTests_Bridge {
    @Test @MainActor func testFocusOnHistorySearchesAndInsertsViaSelectedText() async throws { await ReplyInserterTests().testFocusOnHistorySearchesAndInsertsViaSelectedText() }
    @Test @MainActor func testFocusedEditableUsedDirectly() async throws { await ReplyInserterTests().testFocusedEditableUsedDirectly() }
    @Test @MainActor func testFallbackOrderFocusThenClick() async throws { await ReplyInserterTests().testFallbackOrderFocusThenClick() }
    @Test @MainActor func testSelectedTextUnsupportedFallsBackToCommandVOnce() async throws { await ReplyInserterTests().testSelectedTextUnsupportedFallsBackToCommandVOnce() }
    @Test @MainActor func testSelectedTextReportedOKButValueUnchangedFallsBackToCommandV() async throws { await ReplyInserterTests().testSelectedTextReportedOKButValueUnchangedFallsBackToCommandV() }
    @Test @MainActor func testUnreadableValueTrustsAPIAndDoesNotDoublePaste() async throws { await ReplyInserterTests().testUnreadableValueTrustsAPIAndDoesNotDoublePaste() }
    @Test @MainActor func testNoCommandVWhenFocusCouldNotBeSet() async throws { await ReplyInserterTests().testNoCommandVWhenFocusCouldNotBeSet() }
    @Test @MainActor func testNotFoundOnlySearchAndSecure() async throws { await ReplyInserterTests().testNotFoundOnlySearchAndSecure() }
    @Test @MainActor func testActivationFailureDoesNothingButCopy() async throws { await ReplyInserterTests().testActivationFailureDoesNothingButCopy() }
    @Test @MainActor func testUntrustedCopiesOnly() async throws { await ReplyInserterTests().testUntrustedCopiesOnly() }
    @Test @MainActor func testClipboardKeptAndNoRetrigger() async throws { await ReplyInserterTests().testClipboardKeptAndNoRetrigger() }
    @Test @MainActor func testLogLineHasNoText() async throws { await ReplyInserterTests().testLogLineHasNoText() }
}

@Suite("ClipboardOverrideTests", .serialized) struct ClipboardOverrideTests_Bridge {
    @Test @MainActor func testNewCopyDuringReplyOverrides() async throws { ClipboardOverrideTests().testNewCopyDuringReplyOverrides() }
    @Test @MainActor func testCtrlOptTTranslatorWithoutContextAlsoOverrides() async throws { ClipboardOverrideTests().testCtrlOptTTranslatorWithoutContextAlsoOverrides() }
    @Test @MainActor func testSelfCopyDuringReplyStillIgnored() async throws { ClipboardOverrideTests().testSelfCopyDuringReplyStillIgnored() }
    @Test @MainActor func testSameTextAsCurrentIgnored() async throws { ClipboardOverrideTests().testSameTextAsCurrentIgnored() }
    @Test @MainActor func testFiltersStillApplyDuringReply() async throws { ClipboardOverrideTests().testFiltersStillApplyDuringReply() }
    @Test @MainActor func testBusyStatesStillNotInterrupted() async throws { ClipboardOverrideTests().testBusyStatesStillNotInterrupted() }
    @Test @MainActor func testKindsForIdleAndReading() async throws { ClipboardOverrideTests().testKindsForIdleAndReading() }
    @Test @MainActor func testLegacyIsBusyAndOnEnglishTextStillWork() async throws { ClipboardOverrideTests().testLegacyIsBusyAndOnEnglishTextStillWork() }
}

@Suite("ReplySessionTests", .serialized) struct ReplySessionTests_Bridge {
    @Test func testOverrideStashesDraftAndUpdatesSource() async throws { ReplySessionTests().testOverrideStashesDraftAndUpdatesSource() }
    @Test func testDraftRestoredOnlyForSameSource() async throws { ReplySessionTests().testDraftRestoredOnlyForSameSource() }
    @Test func testSameSourceNewCopyRestoresDraft() async throws { ReplySessionTests().testSameSourceNewCopyRestoresDraft() }
    @Test func testEscapeDropsDraft() async throws { ReplySessionTests().testEscapeDropsDraft() }
    @Test func testEmptyDraftNotStashedAndReadingReplaceDoesNotLeaveReply() async throws { ReplySessionTests().testEmptyDraftNotStashedAndReadingReplaceDoesNotLeaveReply() }
    @Test func testUnknownNewSourceKeepsPrevious() async throws { ReplySessionTests().testUnknownNewSourceKeepsPrevious() }
}

@Suite("ReplyCancelTests", .serialized) struct ReplyCancelTests_Bridge {
    @Test @MainActor func testCancelledAfterActivationDoesNotInsertOrPaste() async throws { await ReplyCancelTests().testCancelledAfterActivationDoesNotInsertOrPaste() }
    @Test @MainActor func testCancelledBeforePasteFallback() async throws { await ReplyCancelTests().testCancelledBeforePasteFallback() }
}

@Suite("ShellCommandFilterTests", .serialized) struct ShellCommandFilterTests_Bridge {
    @Test func testTerminalCommandsAreIgnored() async throws { ShellCommandFilterTests().testTerminalCommandsAreIgnored() }
    @Test func testNaturalEnglishStillTranslates() async throws { ShellCommandFilterTests().testNaturalEnglishStillTranslates() }
    @Test func testMostCommandsHitShellRuleSpecifically() async throws { ShellCommandFilterTests().testMostCommandsHitShellRuleSpecifically() }
    @Test func testScoringBasics() async throws { ShellCommandFilterTests().testScoringBasics() }
}

@Suite("TranslationServiceTests", .serialized) struct TranslationServiceTests_Bridge {
    @Test func testChineseInputTranslatesToEnglish() async throws { try await TranslationServiceTests().testChineseInputTranslatesToEnglish() }
    @Test func testEnglishInputTranslatesToChinese() async throws { try await TranslationServiceTests().testEnglishInputTranslatesToChinese() }
    @Test func testEmptyAndUnknownThrow() async throws { await TranslationServiceTests().testEmptyAndUnknownThrow() }
    @Test func testFallsBackWhenFirstProviderThrows() async throws { try await TranslationServiceTests().testFallsBackWhenFirstProviderThrows() }
    @Test func testSkipsUnavailableProvider() async throws { try await TranslationServiceTests().testSkipsUnavailableProvider() }
    @Test func testTimeoutFallsBack() async throws { try await TranslationServiceTests().testTimeoutFallsBack() }
    @Test func testAllFailThrowsLastError() async throws { await TranslationServiceTests().testAllFailThrowsLastError() }
    @Test func testNoProvidersThrows() async throws { await TranslationServiceTests().testNoProvidersThrows() }
    @Test func testCancellationDoesNotFallBack() async throws { try await TranslationServiceTests().testCancellationDoesNotFallBack() }
    @Test func testCacheAvoidsSecondCall() async throws { try await TranslationServiceTests().testCacheAvoidsSecondCall() }
    @Test func testBaiduRequestSignatureAndParsing() async throws { try await TranslationServiceTests().testBaiduRequestSignatureAndParsing() }
    @Test func testBaiduErrorResponseThrows() async throws { await TranslationServiceTests().testBaiduErrorResponseThrows() }
    @Test func testLibreTranslateParsing() async throws { try await TranslationServiceTests().testLibreTranslateParsing() }
    @Test func testOnlineFactoryDisabledByDefault() async throws { TranslationServiceTests().testOnlineFactoryDisabledByDefault() }
}

@Suite("VocabularyTests", .serialized) struct VocabularyTests_Bridge {
    @Test func testFirstPlayCreatesEntry() async throws { try await VocabularyTests().testFirstPlayCreatesEntry() }
    @Test func testRepeatedPlayIncrementsCountWithoutDuplicates() async throws { await VocabularyTests().testRepeatedPlayIncrementsCountWithoutDuplicates() }
    @Test func testNormalizationDeduplicates() async throws { await VocabularyTests().testNormalizationDeduplicates() }
    @Test func testDifferentChineseForSameEnglishAreKept() async throws { await VocabularyTests().testDifferentChineseForSameEnglishAreKept() }
    @Test func testEmptyOrPunctuationOnlyIgnored() async throws { await VocabularyTests().testEmptyOrPunctuationOnlyIgnored() }
    @Test func testConcurrentPlaysAreAllCounted() async throws { await VocabularyTests().testConcurrentPlaysAreAllCounted() }
    @Test func testPersistsAcrossInstances() async throws { await VocabularyTests().testPersistsAcrossInstances() }
    @Test func testRecordDoesNotWriteSynchronouslyAndFlushDoes() async throws { await VocabularyTests().testRecordDoesNotWriteSynchronouslyAndFlushDoes() }
    @Test func testDebouncedBackgroundWriteHappensOnItsOwn() async throws { try await VocabularyTests().testDebouncedBackgroundWriteHappensOnItsOwn() }
    @Test func testBurstOfWritesIsCoalesced() async throws { try await VocabularyTests().testBurstOfWritesIsCoalesced() }
    @Test func testFileHasStableJSONSchema() async throws { try await VocabularyTests().testFileHasStableJSONSchema() }
    @Test func testCorruptFileIsQuarantinedNotOverwritten() async throws { try await VocabularyTests().testCorruptFileIsQuarantinedNotOverwritten() }
    @Test func testRemoveAndRemoveAll() async throws { await VocabularyTests().testRemoveAndRemoveAll() }
    @Test func testCSVExportEscapingAndBOM() async throws { try await VocabularyTests().testCSVExportEscapingAndBOM() }
    @Test func testJSONExportRoundTrips() async throws { try await VocabularyTests().testJSONExportRoundTrips() }
}

@Suite("VocabularyIntegrationTests", .serialized) struct VocabularyIntegrationTests_Bridge {
    @Test @MainActor func testClickingPronounceAddsEntryAndCountsPlays() async throws { await VocabularyIntegrationTests().testClickingPronounceAddsEntryAndCountsPlays() }
    @Test @MainActor func testEnglishSourceClickAddsEntry() async throws { await VocabularyIntegrationTests().testEnglishSourceClickAddsEntry() }
    @Test @MainActor func testEnglishSourceAndChineseSourceShareDedupedEntry() async throws { await VocabularyIntegrationTests().testEnglishSourceAndChineseSourceShareDedupedEntry() }
    @Test @MainActor func testEnglishSourceNoClickNoEntry() async throws { try await VocabularyIntegrationTests().testEnglishSourceNoClickNoEntry() }
    @Test @MainActor func testNoClickNoFileEvenAfterManyTranslations() async throws { try await VocabularyIntegrationTests().testNoClickNoFileEvenAfterManyTranslations() }
    @Test @MainActor func testPronounceTapStaysFastWithLargeBook() async throws { try await VocabularyIntegrationTests().testPronounceTapStaysFastWithLargeBook() }
    @Test @MainActor func testEnglishSourceTapStaysFastWithLargeBook() async throws { try await VocabularyIntegrationTests().testEnglishSourceTapStaysFastWithLargeBook() }
}

#endif
