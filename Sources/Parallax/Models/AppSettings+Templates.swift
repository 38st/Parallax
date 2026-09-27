import Foundation
import Observation

extension AppSettings {
    var profileTemplateNames: [String] {
        profileTemplates.map(\.name)
    }

    func profileTemplate(id: ProfileTemplate.ID) -> ProfileTemplate? {
        profileTemplates.first { $0.id == id }
    }

    @discardableResult
    func addProfileTemplate(named name: String) -> ProfileTemplate.ID? {
        guard canModifySettings else { return nil }
        guard let normalizedName = DisplayNameValidator.normalized(name) else {
            return nil
        }
        let template = ProfileTemplate(name: normalizedName)
        profileTemplates.append(template)
        return profileTemplates.contains(where: { $0.id == template.id }) ? template.id : nil
    }

    @discardableResult
    func replaceProfileTemplate(_ template: ProfileTemplate) -> Bool {
        guard canModifySettings else { return false }
        guard let index = profileTemplates.firstIndex(where: {
            $0.id == template.id
        }) else {
            return false
        }
        var normalizedTemplate = template
        if template.name != profileTemplates[index].name {
            guard let normalizedName = DisplayNameValidator.normalized(template.name) else {
                return false
            }
            normalizedTemplate.name = normalizedName
        }
        guard profileTemplates[index] != normalizedTemplate else {
            return true
        }
        profileTemplates[index] = normalizedTemplate
        return profileTemplates[index] == normalizedTemplate
    }

    @discardableResult
    func removeProfileTemplate(id: ProfileTemplate.ID) -> Bool {
        guard canModifySettings else { return false }
        guard let index = profileTemplates.firstIndex(where: {
            $0.id == id
        }) else {
            return false
        }
        profileTemplates.remove(at: index)
        return true
    }
}
