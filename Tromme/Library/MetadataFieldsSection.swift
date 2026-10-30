import SwiftUI

struct MetadataFieldsSection: View {
    @Bindable var viewModel: EditMetadataViewModel

    var body: some View {
        Section {
            LabeledContent("Title") {
                TextField("Title", text: $viewModel.title)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Artist") {
                TextField("Artist", text: $viewModel.artist)
                    .multilineTextAlignment(.trailing)
            }
            if viewModel.isTrack {
                LabeledContent("Album") {
                    TextField("Album", text: $viewModel.album)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Track Number") {
                    TextField("Number", text: $viewModel.trackNumberText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Year") {
                TextField("Year", text: $viewModel.yearText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
        } footer: {
            Text(viewModel.isTrack
                 ? "Changing the album or artist moves this track. A name that already exists merges into it."
                 : "Renaming to an existing album or artist merges into it.")
        }
    }
}
