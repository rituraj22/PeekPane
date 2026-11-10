cask "peekpane" do
  version "1.1"
  sha256 "b0f23c0a4c9bdb9073cd120c841aa0f365179e2f669cc855b70d351e269727f2"

  url "https://github.com/rituraj22/PeekPane/releases/download/v#{version}/PeekPane-#{version}-macos.zip"
  name "PeekPane"
  desc "Turn any slice of any Mac window into a live, always-on-top, click-through floating pane"
  homepage "https://github.com/rituraj22/PeekPane"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "PeekPane.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/PeekPane.app"],
                   sudo: false
    system_command "/usr/bin/tccutil",
                   args: ["reset", "ScreenCapture", "com.peekpane.app"],
                   sudo: false,
                   must_succeed: false
    system_command "/usr/bin/tccutil",
                   args: ["reset", "Accessibility", "com.peekpane.app"],
                   sudo: false,
                   must_succeed: false
  end

  zap trash: [
    "~/Library/Preferences/com.peekpane.app.plist",
    "~/Library/Saved Application State/com.peekpane.app.savedState",
  ]
end
