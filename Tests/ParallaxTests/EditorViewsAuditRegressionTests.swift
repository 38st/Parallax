import Observation
import XCTest
@testable import Parallax

final class EditorViewsAuditRegressionTests: XCTestCase {
    func testNewSpaceWithoutPreferenceDefaultsToWork() {
        let draft = NewSpaceDraft(choices: NewSpaceChoice.available(templates: ProfileTemplate.defaults))
        XCTAssertEqual(draft.choice.title, "Work")
    }

    func testSubdivisionFlagIsAcceptedButDetachedTagsAreRejected() {
        XCTAssertTrue(DisplayNameValidator.validate("\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}").isValid)
        XCTAssertFalse(DisplayNameValidator.validate("Name\u{E0067}\u{E007F}").isValid)
    }

    func testInvisibleFillersAreNotVisibleNames() {
        for value in ["\u{3164}", "\u{2800}", "\u{115F}", "\u{1160}", "\u{FFA0}", "\u{3164} \u{2800}"] {
            XCTAssertFalse(DisplayNameValidator.validate(value).isValid, value.debugDescription)
        }
    }

    func testRunningInstanceFormatsHaveEnglishAndSpanishSingulars() throws {
        for language in ["en", "es"] {
            let path = try XCTUnwrap(PackagedRuntimeResources.bundle.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let locale = Locale(identifier: language)
            XCTAssertEqual(String(localized: "\(1) running instances", bundle: bundle, locale: locale),
                           language == "en" ? "1 running instance" : "1 instancia en ejecución")
            XCTAssertEqual(String(localized: "Parallax, \(1) running instances", bundle: bundle, locale: locale),
                           language == "en" ? "Parallax, 1 running instance" : "Parallax, 1 instancia en ejecución")
        }
    }

    func testTemplateRenameAndRemovalKeepPickerSelectionValid() throws {
        let templates = ProfileTemplate.defaults
        let choices = NewSpaceChoice.available(templates: templates)
        var draft = NewSpaceDraft(choices: choices)
        let renamed = choices.map {
            NewSpaceChoice(kind: $0.kind, title: $0.id == draft.choice.id ? "Renamed" : $0.title)
        }
        draft.synchronizeChoices(renamed)
        XCTAssertEqual(draft.name, "Renamed")
        XCTAssertTrue(renamed.contains(draft.choice))
        draft.name = "Custom name"
        let withoutSelection = renamed.filter { $0.id != draft.choice.id }
        draft.synchronizeChoices(withoutSelection)
        XCTAssertEqual(draft.choice.kind, .blank)
        XCTAssertEqual(draft.name, "Custom name")
        XCTAssertTrue(withoutSelection.contains(draft.choice))
    }

    func testUnchangedLegacyNamesDoNotBlockOtherEdits() {
        let baseline = LaunchProfile(name: "\u{3164}")
        var draft = baseline
        draft.notes = "Changed notes"
        let presentation = SpaceEditorActionPresentation(draft: draft, baseline: baseline)
        XCTAssertTrue(presentation.canSave)
        XCTAssertNil(presentation.nameValidationMessage)
        let app = ManagedApplication(displayName: "\u{2800}", appPath: "/tmp/Synthetic.app")
        var appDraft = app
        appDraft.appPath = "/tmp/Relocated.app"
        let appPresentation = ApplicationSettingsActionPresentation(draft: appDraft, baseline: app)
        XCTAssertTrue(appPresentation.canSave)
        XCTAssertNil(appPresentation.nameValidationMessage)
    }
    func testInvalidChangedNamesStillBlockSave() {
        let baseline = LaunchProfile(name: "Work")
        var draft = baseline
        draft.name = "\u{3164}"
        XCTAssertFalse(SpaceEditorActionPresentation(draft: draft, baseline: baseline).canSave)
        let app = ManagedApplication(displayName: "Synthetic", appPath: "/tmp/Synthetic.app")
        var appDraft = app
        appDraft.displayName = "\u{2800}"
        XCTAssertFalse(ApplicationSettingsActionPresentation(draft: appDraft, baseline: app).canSave)
    }

    func testRunningPopoverStaysClosedAfterInstancesReturnOrApplicationChanges() {
        var presentation = RunningInstancesPresentation(isPresented: true)
        presentation.instancesDidChange(isEmpty: true)
        XCTAssertFalse(presentation.isPresented)
        presentation.instancesDidChange(isEmpty: false)
        XCTAssertFalse(presentation.isPresented)
        presentation.isPresented = true
        presentation.applicationDidChange()
        XCTAssertFalse(presentation.isPresented)
    }

    func testArgumentPreviewRedactsUsingSelectedLanguage() throws {
        let reference = EnvironmentSecretReference()
        for language in ["en", "es"] {
            let path = try XCTUnwrap(PackagedRuntimeResources.bundle.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let preview = ProfileEditorSecurityPresentation.argumentPreview(
                for: "--token synthetic \(reference.token)", bundle: bundle,
                locale: Locale(identifier: language)
            )
            XCTAssertEqual(preview.prefix(2), ["--token", language == "es" ? "<redactado>" : "<redacted>"])
            XCTAssertFalse(preview.joined().contains("synthetic"))
            XCTAssertFalse(preview.joined().contains(reference.token))
        }
    }

    func testSpanishDiscardUsesApplicationTerminology() throws {
        let path = try XCTUnwrap(PackagedRuntimeResources.bundle.path(forResource: "es", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(
            String(localized: "Discard unsaved app changes?", bundle: bundle, locale: Locale(identifier: "es")),
            "¿Descartar los cambios de la aplicación sin guardar?"
        )
    }

    @MainActor
    func testNewSpaceChoicesObserveTemplateRenameAndDeletion() throws {
        let settings = AppSettings()
        let application = ManagedApplication(displayName: "Synthetic", appPath: "/tmp/Synthetic.app")
        let store = LibraryStore(
            persistence: EditorAuditPersistence(applications: [application]), settings: settings
        )
        let view = NewSpaceView(store: store, application: application)
        var template = try XCTUnwrap(settings.profileTemplates.first)
        let renamed = expectation(description: "Observed template change")
        let initialChoices = withObservationTracking {
            view.choices
        } onChange: {
            renamed.fulfill()
        }
        XCTAssertTrue(initialChoices.contains { $0.templateID == template.id })
        template.name = "Renamed"
        XCTAssertTrue(settings.replaceProfileTemplate(template))
        XCTAssertTrue(view.choices.contains { $0.templateID == template.id && $0.title == "Renamed" })
        XCTAssertTrue(settings.removeProfileTemplate(id: template.id))
        XCTAssertFalse(view.choices.contains { $0.templateID == template.id })
        wait(for: [renamed], timeout: 1)
    }

    @MainActor
    func testStagingErrorsAreOwnedBySecretSheetUntilDismissed() async {
        let store = LibraryStore(
            persistence: EditorAuditPersistence(applications: []),
            secretStore: EditorAuditSecretStore(failsToStore: true)
        )
        store.sceneCoordinator.isShowingKeychainSecretSheet = true
        let result = await store.stageKeychainSecret(
            "synthetic", environmentKey: "INVALID NAME", in: LaunchProfile(name: "Work")
        )
        XCTAssertNil(result)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.sceneCoordinator.presentsWorkspaceErrors)
        store.errorMessage = nil
        let failedStore = await store.stageKeychainSecret(
            "synthetic", environmentKey: "TOKEN", in: LaunchProfile(name: "Work")
        )
        XCTAssertNil(failedStore)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.sceneCoordinator.presentsWorkspaceErrors)
        store.sceneCoordinator.isShowingKeychainSecretSheet = false
        XCTAssertTrue(store.sceneCoordinator.presentsWorkspaceErrors)
        store.sceneCoordinator.isShowingApplicationSettings = true
        XCTAssertFalse(store.sceneCoordinator.presentsWorkspaceErrors)
    }

}
