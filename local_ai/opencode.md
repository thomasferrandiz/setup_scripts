In 1 terminal:
```bash
brew install mlx-lm
python3 -m mlx_lm.server \
  --model mlx-community/Qwen3.5-35B-A3B-4bit \
  --port 11434 \
  --max-tokens 32768
```

Edit `~/.config/opencode/opencode.jsonc`:
```json
{
  "$schema": "https://opencode.ai/config.json",
  "disabled_providers": [],
  "provider": {
    "mlx_lm": {
      "name": "mlx_lm",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://localhost:11434/v1"
      },
      "models": {
        "mlx-community/Qwen3.5-35B-A3B-4bit": {
          "name": "qwen3.5"
        }
      }
    }
  }
}
```

In another:
```bash
cd <path/to/project>
opencode .
```

```
/connect
choose mlx_lm
key is None or fake-key-local
```