import SwiftUI

struct TagPickerView: View {
    let kind: TagKind
    @Bindable var viewModel: EditTagsViewModel
    @State private var query = ""

    private var options: [String] {
        let all = viewModel.allSuggestions(for: kind)
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(options, id: \.self) { option in
            let isSelected = viewModel.contains(option, in: kind)
            Button {
                viewModel.toggle(option, in: kind)
            } label: {
                HStack {
                    Text(option)
                        .foregroundStyle(.primary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .overlay {
            if options.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        TagPickerView(
            kind: .genre,
            viewModel: EditTagsViewModel(item: PlexMetadata(ratingKey: "1", title: "Album", type: "album"))
        )
    }
}
