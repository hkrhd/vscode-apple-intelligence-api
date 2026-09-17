export default {
  branches: ["main"],
  tagFormat: "v${version}",
  plugins: [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    [
      "@semantic-release/exec",
      {
        prepareCmd: "zsh scripts/prepare-release.zsh ${nextRelease.version}",
        publishCmd: "zsh scripts/publish-marketplace.zsh",
      },
    ],
    [
      "@semantic-release/github",
      {
        assets: [
          {
            path: ".artifacts/vscode-apple-intelligence-api-darwin-arm64.vsix",
            label: "Apple Intelligence API for macOS Apple Silicon",
          },
        ],
        successComment: false,
        failComment: false,
        releasedLabels: false,
      },
    ],
  ],
};
