import SwiftUI

struct TagsSection: View {
    @Bindable var viewModel: EditTagsViewModel

    var body: some View {
        ForEach(TagKind.allCases, id: \.self) { kind in
            Section(kind.title) {
                ForEach(viewModel.tags[kind] ?? [], id: \.self) { tag in
                    Text(tag)
                }
                .onDelete { viewModel.remove(kind, at: $0) }
                if !viewModel.allSuggestions(for: kind).isEmpty {
                    NavigationLink(kind.addPrompt) {
                        TagPickerView(kind: kind, viewModel: viewModel)
                    }
                }
            }
        }
    }
}

#Preview {
    Form { TagsSection(viewModel: EditTagsViewModel(item: PlexMetadata(ratingKey: "1", title: "Album", type: "album"))) }
}
