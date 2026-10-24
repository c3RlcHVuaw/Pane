import SwiftUI
import PaneModel

struct AutofillPane: View {
    @ObservedObject var store: AutofillStore = .shared
    @State private var editing: AddressProfile?
    @State private var addingCard = false

    var body: some View {
        Form {
            Section {
                if store.addresses.isEmpty { Text("No addresses saved.").foregroundStyle(.secondary) }
                ForEach(store.addresses) { a in
                    HStack(spacing: 12) {
                        badge("house.fill", .blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: a.title).fontWeight(.medium)
                            Text(verbatim: [a.city, a.country].filter { !$0.isEmpty }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = a }
                        Button { store.removeAddress(a.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                Button("Add Address…") { editing = AddressProfile() }
            } header: { Text("Addresses") } footer: {
                Text("Right-click a form field and choose AutoFill to fill in the whole form.")
            }
            Section {
                if store.cards.isEmpty { Text("No cards saved.").foregroundStyle(.secondary) }
                ForEach(store.cards) { c in
                    HStack(spacing: 12) {
                        badge("creditcard.fill", .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: c.title).fontWeight(.medium)
                            Text(verbatim: "\(c.holder) · \(c.expMonth)/\(c.expYear)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { store.removeCard(c.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                Button("Add Card…") { addingCard = true }
            } header: { Text("Cards") } footer: {
                Text("Card numbers are kept in the Keychain and are filled in only after Touch ID or your Mac password. The security code is never saved.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { a in AddressEditor(address: a) { store.upsert($0); editing = nil } cancel: { editing = nil } }
        .sheet(isPresented: $addingCard) { CardEditor(store: store) { addingCard = false } }
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
    }
}

private struct AddressEditor: View {
    @State var address: AddressProfile
    let save: (AddressProfile) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Label (optional)", text: $address.label)
                TextField("Full name", text: $address.fullName)
                TextField("Company", text: $address.organization)
                TextField("Email", text: $address.email)
                TextField("Phone", text: $address.phone)
                TextField("Street address", text: $address.street)
                TextField("Apartment, suite", text: $address.street2)
                TextField("City", text: $address.city)
                TextField("State / region", text: $address.region)
                TextField("Postal code", text: $address.postalCode)
                TextField("Country", text: $address.country)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(address) }.keyboardShortcut(.defaultAction).disabled(address.isEmpty)
            }.padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440, height: 520)
    }
}

private struct CardEditor: View {
    let store: AutofillStore
    let done: () -> Void
    @State private var number = ""
    @State private var holder = ""
    @State private var month = ""
    @State private var year = ""
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Card number", text: $number)
                TextField("Name on card", text: $holder)
                HStack {
                    TextField("Month (MM)", text: $month)
                    TextField("Year (YYYY)", text: $year)
                }
                if failed { Text("Check the card number.").foregroundStyle(.orange) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") {
                    let m = month.count == 1 ? "0" + month : month
                    if store.addCard(number: number, holder: holder, expMonth: m, expYear: year) != nil { done() } else { failed = true }
                }.keyboardShortcut(.defaultAction)
            }.padding([.horizontal, .bottom], 20)
        }
        .frame(width: 400, height: 300)
    }
}
