import CoreData
import SwiftUI

struct PreferenceFields: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("displayCurrencies") private var displayCurrencies = CurrencyPreferences.defaultDisplay
    @AppStorage("defaultCurrency") private var currency = "USD"
    @AppStorage("defaultRole") private var role = ""
    @AppStorage("homeTimeZone") private var homeTimeZone = TimeZone.current.identifier
    @AppStorage("homeLocation") private var homeLocation = ""
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        DaybookSections {
        Section("User settings") {
            Menu {
                Picker("Default currency", selection: $currency) {
                    ForEach(CurrencyPreferences.supported, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                preferenceRow("Default currency", value: currency, indicator: "chevron.up.chevron.down")
            }.accessibilityIdentifier("preference-currency")
            NavigationLink { DisplayCurrencyPicker() } label: {
                preferenceRow("Currencies to display", value: CurrencyPreferences.displayed(displayCurrencies).joined(separator: ", "))
            }.accessibilityIdentifier("preference-display-currencies")
            NavigationLink { DefaultRolePicker(selection: $role) } label: {
                preferenceRow("Default role", value: role.isEmpty ? "None" : role)
            }.accessibilityIdentifier("preference-role")
            NavigationLink { HomeLocationPicker() } label: {
                preferenceRow("Home location", value: homeLocation.isEmpty
                    ? (TimeZone.home.localizedName(for: .generic, locale: .current) ?? TimeZone.home.identifier) : homeLocation)
            }.accessibilityIdentifier("preference-home-location")
                .onAppear {
                    if UserDefaults.standard.object(forKey: "homeTimeZone") == nil {
                        homeTimeZone = TimeZone.current.identifier
                    }
                }
            appearanceRow
        }
        }
    }

    // The segments sit beside the label when they fit, and below it when they don't.
    @ViewBuilder private var appearanceRow: some View {
        if typeSize.isAccessibilitySize {
            appearancePicker.pickerStyle(.menu).frame(minHeight: 44)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text("Appearance")
                    Spacer(minLength: 8)
                    appearancePicker.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Appearance")
                    appearancePicker.pickerStyle(.segmented).labelsHidden()
                }
            }
        }
    }
    // A shared label keeps menu and navigation controls on the same row geometry.
    private func preferenceRow(_ title: String, value: String, indicator: String = "chevron.right") -> some View {
        HStack(spacing: 10) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                    Text(value).foregroundStyle(Color("SecondaryText"))
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LabeledContent(title, value: value)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Image(systemName: indicator)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color("SecondaryText"))
                .frame(width: 12)
        }
        .foregroundStyle(Color.primary)
        .frame(minHeight: 24)
        .contentShape(Rectangle())
    }

    private var appearancePicker: some View {
        Picker("Appearance", selection: $appearance) {
            Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
        }.accessibilityIdentifier("preference-appearance")
    }
}

/// New events and remote work start in the home location's timezone.
private struct HomeLocationPicker: View {
    @AppStorage("homeTimeZone") private var homeTimeZone = TimeZone.current.identifier
    @AppStorage("homeLocation") private var homeLocation = ""
    @StateObject private var zones = PlaceZones()
    @State private var text = ""
    var body: some View {
        DaybookForm {
            Section {
                LocationSearchField(title: "Search for your city", text: $text, identifier: "home-location", onChoose: { suggestion in
                    zones.choose("home", apply: { zone in
                        UserDefaults.standard.set(zone, forKey: "homeTimeZone")
                        UserDefaults.standard.set(suggestion.text, forKey: "homeLocation")
                    }) { try await PlaceZone.resolve(suggestion) }
                }, onEdit: { zones.edited("home") })
                DerivedTimeZoneRow(title: "Home timezone", timeZoneID: homeTimeZone, date: Date(),
                                   caption: "New events use this until you choose their location.",
                                   identifier: "home-timezone", zones: zones, key: "home")
            }
        }
        .navigationTitle("Home location").navigationBarTitleDisplayMode(.inline)
        .onAppear { text = homeLocation }
    }
}

private struct DefaultRolePicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkRole.name, ascending: true)]) private var roles: FetchedResults<WorkRole>
    @State private var custom = ""
    private var choices: [String] {
        Set(roles.map(\.name) + ["Commentator", "Presenter", "Producer", "Crew", selection])
            .filter { !$0.isEmpty }.sorted()
    }
    var body: some View {
        DaybookList {
            Section {
                choice("None", value: "")
                ForEach(choices, id: \.self) { choice($0, value: $0) }
            }
            Section("Custom role") {
                TextField("Role name", text: $custom).textInputAutocapitalization(.words)
                Button("Use role") { selection = custom.trimmingCharacters(in: .whitespacesAndNewlines); dismiss() }
                    .disabled(custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.navigationTitle("Default role").navigationBarTitleDisplayMode(.inline)
    }
    private func choice(_ title: String, value: String) -> some View {
        Button { selection = value; dismiss() } label: {
            HStack { Text(title); Spacer(); if selection == value { Image(systemName: "checkmark") } }
                .frame(minHeight: 44)
        }.accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}

private struct DisplayCurrencyPicker: View {
    @AppStorage("displayCurrencies") private var stored = CurrencyPreferences.defaultDisplay
    private var selected: [String] { CurrencyPreferences.displayed(stored) }

    var body: some View {
        DaybookList {
            Section {
                ForEach(CurrencyPreferences.supported, id: \.self) { code in
                    Toggle(isOn: Binding(
                        get: { selected.contains(code) },
                        set: { enabled in
                            var next = Set(selected)
                            if enabled { next.insert(code) } else { next.remove(code) }
                            if !next.isEmpty {
                                stored = CurrencyPreferences.supported.filter { next.contains($0) }.joined(separator: ",")
                            }
                        }
                    )) {
                        Text(code)
                    }
                    .disabled(selected.count == 1 && selected.contains(code))
                    .accessibilityIdentifier("display-currency-\(code)")
                }
            } footer: {
                Text("Choose at least one currency for the Payments summary. Totals stay separate, with no currency conversion. You can still enter fees, invoices and expenses in any supported currency.")
            }
        }
        .navigationTitle("Currencies to display")
        .navigationBarTitleDisplayMode(.inline)
    }
}
