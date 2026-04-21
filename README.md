# Git History LLM Rewrite

A tool that uses Local LLMs (via Ollama) to automatically rewrite messy git commit history into professional Conventional Commits.

## Features

- **AI-Powered**: Uses Ollama to analyze changed files and original messages to generate accurate conventional commits.
- **Two-Step Process**: Generates a mapping file for review before actually modifying your history.
- **Resume Support**: Picks up where it left off if the generation is interrupted.
- **Safety First**: Automatically creates a backup branch and handles stashing of uncommitted changes.
- **Conventional Standard**: Supports feat, fix, chore, docs, refactor, style, perf, test, ci, and build.

## Getting Started

### Prerequisites

1.  **Ollama**: [Download and install Ollama](https://ollama.com/).
2.  **Model**: Pull a capable model (e.g., qwen3.5:9b or llama3:8b).
    ```bash
    ollama pull qwen3.5:9b
    ```
3.  **Bash Environment**: Works on Linux, macOS, and WSL.

### Installation

Clone this repository or download the `git-rewrite-ai.sh` script.

### Usage

#### Step 1: Generate the mapping
Go to your target repository and run the script:
```bash
cd /path/to/your/repo
bash /path/to/git-rewrite-ai.sh --model qwen3.5:9b
```
This creates a `mapping.txt` file in your repository root. Review this file and manually edit any messages if necessary.

#### Step 2: Apply the changes
Once you are satisfied with the `mapping.txt`, apply it:
```bash
bash /path/to/git-rewrite-ai.sh --apply
```
The script will rewrite the history of your current branch. A backup branch named `backup-before-rewrite-...` is created automatically.

## GPU vs CPU Optimization (Ollama)

Running LLMs locally hardware-intensive. Here is how to optimize for your setup:

### GPU (Recommended)
If you have an NVIDIA or Mac (M-series) GPU, Ollama will use it automatically.
- **Benefits**: Faster generation (seconds per commit).
- **Tip**: Use larger models like `qwen3.5:9b` for better quality.

### CPU
If you don't have a dedicated GPU, Ollama will run on your CPU.
- **Optimization**: Use smaller, specialized models to maintain speed.
- **Recommended Models for CPU**:
    - `qwen3.5:2b` (Fast on CPU)
    - `phi3:mini` (Excellent performance for its size)
- **Speed**: Generation might take 2-10 seconds per commit depending on your processor.

### Ollama Environment Variables
Control hardware usage via environment variables before starting the Ollama server:
- `OLLAMA_NUM_PARALLEL=4`: Process multiple requests.
- `CUDA_VISIBLE_DEVICES`: Force Ollama to use a specific GPU.

## Important Notes

- **Git History**: This script rewrites history. Commit hashes will change. Only use this on local branches or repositories where you are the sole contributor.
- **Force Push**: After applying, you will need to `git push --force` to update remote branches.
- **Backup**: Always verify the backup branch before deleting it.

## Options

| Option | Description | Default |
| :--- | :--- | :--- |
| --model | The Ollama model to use | qwen3.5:9b |
| --mapping | Path to the mapping file | mapping.txt |
| --apply | Apply the mapping to git history | (disabled) |
| --help | Show help message | |
