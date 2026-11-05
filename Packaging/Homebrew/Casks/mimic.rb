# Source of truth for srpadrono/homebrew-tap's Casks/mimic.rb. Copy it there after each release with
# the version and the sha256 the Release workflow prints in its summary (CONTRIBUTING ▸ Releases).
cask "mimic" do
  version "0.15.0"
  sha256 "b7edb065aab7e2c31a1f8981eb41903dd4cfd729439999e1327e9067755939ac"

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
