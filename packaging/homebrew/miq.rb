# Homebrew formula for the `miq` command-line tool (info / render / mosaic).
#
# This file is the source of truth; copy it to `Formula/miq.rb` in the tap
# (github.com/marcoduering/homebrew-miq) when releasing — see RELEASING.md,
# "CLI (Homebrew formula and universal binary)". The tap's `Casks/miq.rb`
# installs the app; this formula only builds the CLI, from the tagged source
# tarball, with no third-party dependencies.
#
# Because the tap also has a cask named `miq`, install the formula with
#   brew install --HEAD --formula marcoduering/miq/miq
class Miq < Formula
  desc "Inspect and render NIfTI, MGH/MGZ, MRtrix MIF, NRRD and MetaImage volumes"
  homepage "https://miq.marco-duering.net"
  # HEAD-only until the first tagged release that contains the CLI; install
  # with `brew install --HEAD --formula marcoduering/miq/miq`. From that
  # release on, add `url` (tag tarball) and the `sha256` that
  # scripts/release_github.sh prints — see RELEASING.md.
  license "MIT"
  head "https://github.com/marcoduering/MIQ.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  uses_from_macos "zlib"

  def install
    # SwiftPM's own sandbox can't nest inside Homebrew's build sandbox.
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "miq"
    bin.install ".build/release/miq"
  end

  test do
    assert_match "USAGE", shell_output("#{bin}/miq --help")
  end
end
