# Source of truth for srpadrono/homebrew-tap's Casks/mimic.rb. Publishing a release opens the tap's
# pull request with this file at the tag, with only `version` and `sha256` replaced
# (.github/workflows/homebrew-tap.yml, CONTRIBUTING ▸ Releases). Keep both lines' shape.
cask "mimic" do
  version "0.16.0"
  sha256 "d3de83c51d532413eb18526d4c1c467fb8d10a9ac5cb865f6ba4dee60a49946e"

  url "https://github.com/srpadrono/mimic/releases/download/v#{version}/Mimic-#{version}.pkg"
  name "Mimic"
  desc "Local mock API server with a native app and CLI"
  homepage "https://github.com/srpadrono/mimic"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Mimic checks GitHub for new versions itself; an organisation that pins versions turns that off
  # with the `updates.disabled` managed preference (README ▸ Managed installs).
  auto_updates true
  depends_on macos: ">= :tahoe"

  pkg "Mimic-#{version}.pkg"

  uninstall quit:    "devxa.Mimic",
            pkgutil: "devxa.Mimic.installer"

  zap trash: [
    "~/Library/Application Scripts/devxa.Mimic",
    "~/Library/Containers/devxa.Mimic",
  ]
end
