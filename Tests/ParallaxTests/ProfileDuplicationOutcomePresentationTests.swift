import Foundation
import XCTest
@testable import Parallax

final class ProfileDuplicationOutcomePresentationTests: XCTestCase {
  func testDataAndExternalConfigurationCombinations() {
    let cases: [(
      name: String,
      dataMutation: ProfileDataMutation,
      externalDataHandling: ProfileExternalDataHandling,
      expected: String
    )] = [
      (
        name: "managed data and external configuration",
        dataMutation: .copiedManagedData,
        externalDataHandling: .configurationOnly(
          configuredPaths: ["/external/profile"]
        ),
        expected:
          "Copied managed profile data to Personal Copy. Explicit external data locations were not copied."
      ),
      (
        name: "managed data without external configuration",
        dataMutation: .copiedManagedData,
        externalDataHandling: .notConfigured,
        expected: "Copied managed profile data to Personal Copy."
      ),
      (
        name: "no managed data and external configuration",
        dataMutation: .noManagedData,
        externalDataHandling: .configurationOnly(
          configuredPaths: ["/external/profile"]
        ),
        expected:
          "Duplicated the configuration as Personal Copy. No managed data existed to copy, and explicit external data locations were not copied."
      ),
      (
        name: "no managed data or external configuration",
        dataMutation: .noManagedData,
        externalDataHandling: .notConfigured,
        expected:
          "Duplicated the configuration as Personal Copy. No managed data existed to copy."
      ),
    ]

    for testCase in cases {
      let outcome = ProfileDataTransactionOutcome(
        transactionID: UUID(),
        operation: .duplicate,
        dataMutation: testCase.dataMutation,
        externalDataHandling: testCase.externalDataHandling,
        didArchiveData: false,
        archiveURL: nil,
        receiptURL: URL(fileURLWithPath: "/receipt.json")
      )

      XCTAssertEqual(
        ProfileDuplicationOutcomePresentation.message(
          for: outcome,
          profileName: "Personal Copy"
        ),
        testCase.expected,
        testCase.name
      )
    }
  }
}
