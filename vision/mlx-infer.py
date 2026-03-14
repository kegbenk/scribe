#!/usr/bin/env python3
"""
MLX vision model inference server for PDF fidelity pipeline.

Two modes:
  1. Single-shot:  mlx-infer.py --image page.png --prompt "..." [--max-tokens 4096]
  2. Batch (stdin): mlx-infer.py --batch
     Reads JSON lines from stdin: {"image": "path.png", "prompt": "...", "max_tokens": 4096}
     Writes JSON lines to stdout: {"text": "...", "tokens": 123, "tps": 22.5}

Batch mode keeps the model loaded across requests (much faster for 187-page runs).
"""

import sys
import os
import json
import argparse
import time

# Ensure HF_HOME points to external drive
if not os.environ.get('HF_HOME'):
    os.environ['HF_HOME'] = '/Volumes/X10 Pro/mlx-models'

from mlx_vlm import load, generate
from mlx_vlm.prompt_utils import apply_chat_template

MODEL_ID = 'mlx-community/Qwen2.5-VL-7B-Instruct-4bit'


def run_inference(model, processor, image_path, prompt_text, max_tokens=4096, temperature=0.1):
    """Run a single vision inference and return the result."""
    prompt = apply_chat_template(
        processor,
        config=model.config,
        prompt=prompt_text,
        num_images=1
    )

    result = generate(
        model, processor, prompt,
        image=[image_path],
        max_tokens=max_tokens,
        verbose=False,
        temp=temperature
    )

    return {
        'text': result.text,
        'prompt_tokens': result.prompt_tokens,
        'generation_tokens': result.generation_tokens,
        'tps': round(result.generation_tps, 1),
        'peak_memory_gb': round(result.peak_memory, 2)
    }


def main():
    parser = argparse.ArgumentParser(description='MLX vision inference for PDF fidelity pipeline')
    parser.add_argument('--image', help='Path to image file (single-shot mode)')
    parser.add_argument('--prompt', help='Prompt text (single-shot mode)')
    parser.add_argument('--max-tokens', type=int, default=4096)
    parser.add_argument('--temperature', type=float, default=0.1)
    parser.add_argument('--batch', action='store_true', help='Batch mode: read JSON lines from stdin')
    parser.add_argument('--model', default=MODEL_ID, help='HuggingFace model ID')
    args = parser.parse_args()

    # Load model once
    print(json.dumps({'status': 'loading', 'model': args.model}), file=sys.stderr, flush=True)
    t0 = time.time()
    model, processor = load(args.model)
    load_time = time.time() - t0
    print(json.dumps({'status': 'ready', 'load_time': round(load_time, 2)}), file=sys.stderr, flush=True)

    if args.batch:
        # Batch mode: read JSON lines from stdin, write results to stdout
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue

            try:
                req = json.loads(line)
                image_path = req['image']
                prompt_text = req['prompt']
                max_tokens = req.get('max_tokens', args.max_tokens)
                temperature = req.get('temperature', args.temperature)

                if not os.path.exists(image_path):
                    print(json.dumps({'error': f'Image not found: {image_path}'}), flush=True)
                    continue

                result = run_inference(model, processor, image_path, prompt_text, max_tokens, temperature)
                print(json.dumps(result), flush=True)

            except json.JSONDecodeError as e:
                print(json.dumps({'error': f'Invalid JSON: {str(e)}'}), flush=True)
            except Exception as e:
                print(json.dumps({'error': str(e)}), flush=True)

    else:
        # Single-shot mode
        if not args.image or not args.prompt:
            parser.error('--image and --prompt required in single-shot mode')

        result = run_inference(model, processor, args.image, args.prompt, args.max_tokens, args.temperature)
        print(json.dumps(result))


if __name__ == '__main__':
    main()
