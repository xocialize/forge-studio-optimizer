# Forge Benchmark Harness — JSON Schema v1.0

**Purpose**: Canonical format for benchmark reports emitted by `BenchmarkSuite` in Phase A.2 of the Forge coding plan, and consumed by CI gate-checking in the pipeline-level acceptance step (§4 of the coding plan).

**Companion to**: Forge-CodingPlan-v1.0.md
**Schema version**: 1.0 (draft 2020-12)
**File naming convention**: `benchmark-<run_label>-<git_sha_short>.json`
Examples: `benchmark-baseline-v0.3-mlx-0.30.x-a1b2c3d.json`, `benchmark-nafnet-eval-mlx-0.31.2-e4f5g6h.json`

---

## 1. Design Notes

A few decisions worth flagging:

- **One file per run.** No appending. Comparison is done by diffing two files; a separate `compare-benchmarks` tool consumes pairs.
- **Per-clip granularity AND aggregate.** Per-clip results live in `pipeline_results.*.runs[]`; aggregates are computed by the comparison tool, not stored — that way aggregate definitions can evolve without invalidating old reports.
- **Speed is reported as a distribution, not a scalar.** `mean`, `median`, `p95`, `p99`, `stddev`. Single numbers lie on video workloads where the first frame is always slower (model load + JIT) and thermal throttling skews tails.
- **`additionalProperties: false` at the top level only.** Nested structures are open so the coder can add fields without bumping the schema version, as long as required fields are still emitted.
- **Hardware fingerprint includes thermal state.** A 1.2× throughput claim measured under thermal pressure is not the same claim as one measured cold. The harness must read `pmset -g thermlog` or equivalent and capture it.
- **Gates are encoded in the report.** CI doesn't need a separate config; it can pass/fail by reading `gates.results[].passed`.

---

## 2. JSON Schema (draft 2020-12)

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://mvscollective.com/schemas/forge-benchmark-v1.0.json",
  "title": "Forge Benchmark Report",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "schema_version",
    "report_id",
    "timestamp_utc",
    "run_label",
    "git",
    "hardware",
    "dependencies",
    "corpus",
    "pipeline_results",
    "gates"
  ],
  "properties": {
    "schema_version": {
      "type": "string",
      "const": "1.0",
      "description": "Schema version; bump on breaking changes only."
    },
    "report_id": {
      "type": "string",
      "format": "uuid",
      "description": "Stable identifier for this report; used as the key when uploading."
    },
    "timestamp_utc": {
      "type": "string",
      "format": "date-time",
      "description": "ISO 8601 UTC timestamp of benchmark start."
    },
    "run_label": {
      "type": "string",
      "pattern": "^[a-z0-9][a-z0-9-]*$",
      "description": "Short label like 'baseline-v0.3-mlx-0.31.2' or 'nafnet-w32b8-eval'."
    },
    "notes": {
      "type": "string",
      "description": "Free-form prose for things the schema can't capture."
    },
    "git": {
      "type": "object",
      "required": ["sha", "branch", "dirty"],
      "properties": {
        "sha": { "type": "string", "pattern": "^[0-9a-f]{7,40}$" },
        "branch": { "type": "string" },
        "dirty": { "type": "boolean", "description": "True if working tree had uncommitted changes." },
        "remote_url": { "type": "string", "format": "uri" }
      }
    },
    "hardware": {
      "type": "object",
      "required": ["model_identifier", "chip", "memory_gb", "os_version", "thermal_state"],
      "properties": {
        "model_identifier": {
          "type": "string",
          "description": "e.g. 'Mac15,9' for M4 Pro Mac Mini; from `sysctl hw.model`."
        },
        "chip": {
          "type": "string",
          "examples": ["M4 Pro", "M5 Pro", "M5 Max", "M4 Max"]
        },
        "cpu_cores": { "type": "integer", "minimum": 1 },
        "gpu_cores": { "type": "integer", "minimum": 1 },
        "memory_gb": { "type": "number", "minimum": 1 },
        "os_version": {
          "type": "string",
          "examples": ["macOS 15.5", "macOS 16.0"]
        },
        "thermal_state": {
          "type": "string",
          "enum": ["nominal", "fair", "serious", "critical"],
          "description": "Captured at run start; affects validity of throughput claims."
        },
        "on_battery": { "type": "boolean", "default": false }
      }
    },
    "dependencies": {
      "type": "object",
      "required": ["mlx_version", "mlx_swift_version", "swift_version"],
      "properties": {
        "mlx_version": { "type": "string", "examples": ["0.30.4", "0.31.2"] },
        "mlx_swift_version": { "type": "string" },
        "swift_version": { "type": "string" },
        "xcode_version": { "type": "string" },
        "ffmpeg_version": { "type": "string" },
        "coreml_runtime": { "type": "string" }
      }
    },
    "corpus": {
      "type": "object",
      "required": ["name", "version", "clips"],
      "properties": {
        "name": { "type": "string", "examples": ["forge-30clip-eval"] },
        "version": { "type": "string" },
        "clips": {
          "type": "array",
          "minItems": 1,
          "items": { "$ref": "#/$defs/CorpusClip" }
        }
      }
    },
    "pipeline_results": {
      "type": "object",
      "properties": {
        "forge_optimizer": { "$ref": "#/$defs/ForgeOptimizerResults" },
        "forge_upscaler": { "$ref": "#/$defs/ForgeUpscalerResults" }
      },
      "minProperties": 1
    },
    "gates": {
      "type": "object",
      "required": ["version", "results"],
      "properties": {
        "version": {
          "type": "string",
          "description": "Gate definition version, matches Forge-CodingPlan §4."
        },
        "results": {
          "type": "array",
          "items": { "$ref": "#/$defs/GateResult" }
        },
        "all_passed": { "type": "boolean" }
      }
    }
  },
  "$defs": {
    "CorpusClip": {
      "type": "object",
      "required": ["id", "category", "resolution", "duration_s", "sha256"],
      "properties": {
        "id": { "type": "string", "examples": ["general-film-01", "signage-static-04"] },
        "category": {
          "type": "string",
          "enum": ["general", "signage", "legacy"]
        },
        "subcategory": {
          "type": "string",
          "examples": ["film", "animation", "sports", "talking-head", "screen-capture",
                       "static-logo", "dynamic-logo", "text-overlay", "transition",
                       "dvd-mpeg2", "broadcast-capture", "interlaced"]
        },
        "resolution": {
          "type": "string",
          "pattern": "^[0-9]+x[0-9]+$",
          "examples": ["1920x1080", "3840x2160", "720x480"]
        },
        "frame_rate": { "type": "number", "minimum": 1 },
        "duration_s": { "type": "number", "minimum": 0 },
        "codec": { "type": "string", "examples": ["h264", "hevc", "mpeg2", "av1"] },
        "sha256": { "type": "string", "pattern": "^[a-f0-9]{64}$" }
      }
    },
    "ForgeOptimizerResults": {
      "type": "object",
      "required": ["bundle_bytes", "model_inventory", "runs"],
      "properties": {
        "bundle_bytes": {
          "type": "integer",
          "minimum": 0,
          "description": "Sum of all .mlpackage bytes in Resources/Models/"
        },
        "model_inventory": {
          "type": "array",
          "items": { "$ref": "#/$defs/ModelInventoryEntry" }
        },
        "runs": {
          "type": "array",
          "items": { "$ref": "#/$defs/OptimizerRun" }
        }
      }
    },
    "ForgeUpscalerResults": {
      "type": "object",
      "required": ["bundle_bytes", "model_inventory", "tiers"],
      "properties": {
        "bundle_bytes": { "type": "integer", "minimum": 0 },
        "model_inventory": {
          "type": "array",
          "items": { "$ref": "#/$defs/ModelInventoryEntry" }
        },
        "tiers": {
          "type": "object",
          "properties": {
            "playback": {
              "type": "array",
              "items": { "$ref": "#/$defs/UpscalerRun" }
            },
            "export": {
              "type": "array",
              "items": { "$ref": "#/$defs/UpscalerRun" }
            },
            "signage": {
              "type": "array",
              "items": { "$ref": "#/$defs/UpscalerRun" }
            }
          }
        }
      }
    },
    "ModelInventoryEntry": {
      "type": "object",
      "required": ["role", "implementation", "size_bytes", "spdx_license"],
      "properties": {
        "role": {
          "type": "string",
          "enum": ["restoration", "denoise", "artifact_removal",
                   "super_resolution_2x", "super_resolution_4x",
                   "saliency", "quality_regressor", "guided_filter",
                   "playback_upscaler", "export_upscaler", "signage_upscaler",
                   "optical_flow"]
        },
        "implementation": {
          "type": "string",
          "description": "Concrete model identifier, e.g. 'NAFNet-w32b8' or 'DnCNN-color-v1'."
        },
        "version": { "type": "string" },
        "size_bytes": { "type": "integer", "minimum": 0 },
        "spdx_license": {
          "type": "string",
          "description": "SPDX identifier from weightLicense field.",
          "examples": ["MIT", "Apache-2.0", "BSD-3-Clause", "CC-BY-4.0", "Proprietary"]
        },
        "format": {
          "type": "string",
          "enum": ["mlpackage", "safetensors", "mlmodelc"]
        }
      }
    },
    "OptimizerRun": {
      "type": "object",
      "required": ["clip_id", "optimization_level", "resolution", "status"],
      "properties": {
        "clip_id": { "type": "string" },
        "optimization_level": {
          "type": "string",
          "enum": ["off", "light", "balanced", "aggressive", "maximum"]
        },
        "resolution": { "type": "string", "pattern": "^[0-9]+x[0-9]+$" },
        "frame_count": { "type": "integer", "minimum": 0 },
        "speed": { "$ref": "#/$defs/SpeedMetrics" },
        "quality": { "$ref": "#/$defs/QualityMetrics" },
        "memory": { "$ref": "#/$defs/MemoryMetrics" },
        "compression": { "$ref": "#/$defs/CompressionMetrics" },
        "status": {
          "type": "string",
          "enum": ["success", "partial", "failed"]
        },
        "failure_reason": { "type": "string" }
      }
    },
    "UpscalerRun": {
      "type": "object",
      "required": ["clip_id", "input_resolution", "output_resolution", "status"],
      "properties": {
        "clip_id": { "type": "string" },
        "input_resolution": { "type": "string", "pattern": "^[0-9]+x[0-9]+$" },
        "output_resolution": { "type": "string", "pattern": "^[0-9]+x[0-9]+$" },
        "scale_factor": { "type": "integer", "minimum": 2, "maximum": 8 },
        "frame_count": { "type": "integer", "minimum": 0 },
        "speed": { "$ref": "#/$defs/SpeedMetrics" },
        "quality": { "$ref": "#/$defs/QualityMetrics" },
        "memory": { "$ref": "#/$defs/MemoryMetrics" },
        "text_metrics": { "$ref": "#/$defs/TextMetrics" },
        "status": {
          "type": "string",
          "enum": ["success", "partial", "failed"]
        },
        "failure_reason": { "type": "string" }
      }
    },
    "SpeedMetrics": {
      "type": "object",
      "required": ["ms_per_frame_mean", "ms_per_frame_median",
                   "ms_per_frame_p95", "ms_per_frame_p99",
                   "ms_per_frame_stddev", "realtime_factor"],
      "properties": {
        "ms_per_frame_mean": { "type": "number", "minimum": 0 },
        "ms_per_frame_median": { "type": "number", "minimum": 0 },
        "ms_per_frame_p95": { "type": "number", "minimum": 0 },
        "ms_per_frame_p99": { "type": "number", "minimum": 0 },
        "ms_per_frame_stddev": { "type": "number", "minimum": 0 },
        "ms_first_frame": {
          "type": "number",
          "minimum": 0,
          "description": "First-frame latency (model load + warmup). Excluded from mean/median."
        },
        "realtime_factor": {
          "type": "number",
          "minimum": 0,
          "description": "Mean throughput / source frame rate. 1.0 = realtime; >1 = faster."
        },
        "fps_mean": { "type": "number", "minimum": 0 }
      }
    },
    "QualityMetrics": {
      "type": "object",
      "properties": {
        "vmaf": { "type": "number", "minimum": 0, "maximum": 100 },
        "vmaf_neg": {
          "type": "number",
          "description": "VMAF-NEG variant; useful for upscaling assessments."
        },
        "psnr_db": { "type": "number" },
        "ssim": { "type": "number", "minimum": 0, "maximum": 1 },
        "ms_ssim": { "type": "number", "minimum": 0, "maximum": 1 },
        "lpips": { "type": "number", "minimum": 0 },
        "siglip2_iqa": {
          "type": "number",
          "minimum": 0,
          "maximum": 1,
          "description": "SigLIP2 NR-IQA score (Phase E.5+)."
        }
      }
    },
    "MemoryMetrics": {
      "type": "object",
      "required": ["peak_bytes"],
      "properties": {
        "peak_bytes": {
          "type": "integer",
          "minimum": 0,
          "description": "Peak unified-memory residency during the run."
        },
        "steady_state_bytes": { "type": "integer", "minimum": 0 },
        "model_resident_bytes": {
          "type": "integer",
          "minimum": 0,
          "description": "Bytes attributable to loaded model weights."
        }
      }
    },
    "CompressionMetrics": {
      "type": "object",
      "required": ["input_bytes", "output_bytes"],
      "properties": {
        "input_bytes": { "type": "integer", "minimum": 0 },
        "output_bytes": { "type": "integer", "minimum": 0 },
        "ratio_vs_baseline": {
          "type": "number",
          "minimum": 0,
          "description": "output / baseline_output, where baseline is the same clip processed at .off."
        },
        "savings_vs_baseline": {
          "type": "number",
          "minimum": 0,
          "maximum": 1,
          "description": "1.0 - ratio_vs_baseline."
        },
        "encoder": {
          "type": "string",
          "examples": ["h264_videotoolbox", "hevc_videotoolbox"]
        },
        "encoder_settings": {
          "type": "object",
          "description": "Free-form encoder parameter capture."
        }
      }
    },
    "TextMetrics": {
      "type": "object",
      "description": "For signage upscaler runs.",
      "properties": {
        "ocr_accuracy": {
          "type": "number",
          "minimum": 0,
          "maximum": 1,
          "description": "Vision OCR character-level accuracy."
        },
        "ocr_word_accuracy": { "type": "number", "minimum": 0, "maximum": 1 },
        "edge_sharpness": {
          "type": "number",
          "description": "Mean gradient magnitude at text edges; higher is sharper."
        }
      }
    },
    "GateResult": {
      "type": "object",
      "required": ["gate_id", "description", "comparison", "target", "actual", "passed"],
      "properties": {
        "gate_id": {
          "type": "string",
          "description": "Stable identifier; matches Forge-CodingPlan §4.",
          "examples": ["bundle_size_max", "throughput_balanced_m4pro_1080p",
                       "vmaf_balanced_min", "compression_balanced_min",
                       "compression_signage_max_min", "playback_4k_fps_min",
                       "quality_regressor_srcc_min"]
        },
        "description": { "type": "string" },
        "comparison": {
          "type": "string",
          "enum": ["lte", "gte", "eq", "lt", "gt"]
        },
        "target": { "type": "number" },
        "actual": { "type": "number" },
        "passed": { "type": "boolean" },
        "hardware_required": {
          "type": "string",
          "description": "If set, gate is only valid when hardware.chip matches.",
          "examples": ["M4 Pro", "M5 Pro"]
        },
        "corpus_subset": {
          "type": "string",
          "description": "If set, restrict measurement to clips in this category.",
          "enum": ["general", "signage", "legacy", "all"]
        },
        "tolerance": {
          "type": "number",
          "description": "Allowed slack on the comparison; pass if abs(actual - target) <= tolerance."
        }
      }
    }
  }
}
```

---

## 3. Complete Example Report

This is a realistic populated example showing one ForgeOptimizer run and one ForgeUpscaler run. The actual harness emits all 30 clips × 5 optimization levels × 2 hardware targets for the optimizer, and 30 clips × 3 tiers for the upscaler.

```json
{
  "schema_version": "1.0",
  "report_id": "0193d7e2-4a8b-7c1d-9e3f-0a1b2c3d4e5f",
  "timestamp_utc": "2026-05-26T18:30:00Z",
  "run_label": "baseline-v0.3-mlx-0.31.2",
  "notes": "First baseline capture after MLX bump from 0.30.4 to 0.31.2 (Phase A.1). Compare against baseline-v0.3-mlx-0.30.4 to validate that 3D-conv speedup is real and nothing regressed.",
  "git": {
    "sha": "a1b2c3d4e5f6789012345678901234567890abcd",
    "branch": "feature/forge-2026-q2-refresh",
    "dirty": false,
    "remote_url": "https://github.com/mvscollective/forge"
  },
  "hardware": {
    "model_identifier": "Mac15,9",
    "chip": "M4 Pro",
    "cpu_cores": 12,
    "gpu_cores": 16,
    "memory_gb": 64,
    "os_version": "macOS 15.5",
    "thermal_state": "nominal",
    "on_battery": false
  },
  "dependencies": {
    "mlx_version": "0.31.2",
    "mlx_swift_version": "0.31.2",
    "swift_version": "6.0",
    "xcode_version": "16.4",
    "ffmpeg_version": "n7.1",
    "coreml_runtime": "8.0"
  },
  "corpus": {
    "name": "forge-30clip-eval",
    "version": "1.0",
    "clips": [
      {
        "id": "general-film-01",
        "category": "general",
        "subcategory": "film",
        "resolution": "1920x1080",
        "frame_rate": 23.976,
        "duration_s": 30.5,
        "codec": "h264",
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      },
      {
        "id": "signage-static-04",
        "category": "signage",
        "subcategory": "static-logo",
        "resolution": "1920x1080",
        "frame_rate": 30.0,
        "duration_s": 60.0,
        "codec": "h264",
        "sha256": "f1d2d2f924e986ac86fdf7b36c94bcdf32beec15c1c6b1de54f97aabe9b8a3c4"
      }
    ]
  },
  "pipeline_results": {
    "forge_optimizer": {
      "bundle_bytes": 14156800,
      "model_inventory": [
        {
          "role": "denoise",
          "implementation": "DnCNN-color-v1.2",
          "version": "1.2",
          "size_bytes": 2400000,
          "spdx_license": "MIT",
          "format": "mlpackage"
        },
        {
          "role": "denoise",
          "implementation": "DnCNN-gray-v1.2",
          "version": "1.2",
          "size_bytes": 800000,
          "spdx_license": "MIT",
          "format": "mlpackage"
        },
        {
          "role": "artifact_removal",
          "implementation": "ARCNN-v1.0",
          "version": "1.0",
          "size_bytes": 1100000,
          "spdx_license": "MIT",
          "format": "mlpackage"
        },
        {
          "role": "super_resolution_2x",
          "implementation": "ESPCN-2x-v1.0",
          "version": "1.0",
          "size_bytes": 240000,
          "spdx_license": "MIT",
          "format": "mlpackage"
        },
        {
          "role": "super_resolution_4x",
          "implementation": "ESPCN-4x-v1.0",
          "version": "1.0",
          "size_bytes": 380000,
          "spdx_license": "MIT",
          "format": "mlpackage"
        },
        {
          "role": "quality_regressor",
          "implementation": "QualityRegressor-CNN-v1.0",
          "version": "1.0",
          "size_bytes": 9236800,
          "spdx_license": "Proprietary",
          "format": "mlpackage"
        }
      ],
      "runs": [
        {
          "clip_id": "general-film-01",
          "optimization_level": "balanced",
          "resolution": "1920x1080",
          "frame_count": 731,
          "speed": {
            "ms_per_frame_mean": 28.4,
            "ms_per_frame_median": 27.9,
            "ms_per_frame_p95": 32.1,
            "ms_per_frame_p99": 35.0,
            "ms_per_frame_stddev": 2.1,
            "ms_first_frame": 184.2,
            "realtime_factor": 1.47,
            "fps_mean": 35.2
          },
          "quality": {
            "vmaf": 92.4,
            "psnr_db": 38.2,
            "ssim": 0.987,
            "ms_ssim": 0.992,
            "lpips": 0.024
          },
          "memory": {
            "peak_bytes": 847000000,
            "steady_state_bytes": 720000000,
            "model_resident_bytes": 14156800
          },
          "compression": {
            "input_bytes": 102400000,
            "output_bytes": 66560000,
            "ratio_vs_baseline": 0.65,
            "savings_vs_baseline": 0.35,
            "encoder": "h264_videotoolbox",
            "encoder_settings": {
              "bitrate_kbps": 3500,
              "profile": "high",
              "level": "4.1"
            }
          },
          "status": "success"
        },
        {
          "clip_id": "signage-static-04",
          "optimization_level": "maximum",
          "resolution": "1920x1080",
          "frame_count": 1800,
          "speed": {
            "ms_per_frame_mean": 67.8,
            "ms_per_frame_median": 66.2,
            "ms_per_frame_p95": 78.4,
            "ms_per_frame_p99": 91.0,
            "ms_per_frame_stddev": 5.3,
            "ms_first_frame": 312.5,
            "realtime_factor": 0.49,
            "fps_mean": 14.7
          },
          "quality": {
            "vmaf": 87.2,
            "psnr_db": 35.9,
            "ssim": 0.974,
            "lpips": 0.041
          },
          "memory": {
            "peak_bytes": 1240000000,
            "steady_state_bytes": 980000000,
            "model_resident_bytes": 14156800
          },
          "compression": {
            "input_bytes": 380000000,
            "output_bytes": 159600000,
            "ratio_vs_baseline": 0.42,
            "savings_vs_baseline": 0.58,
            "encoder": "hevc_videotoolbox",
            "encoder_settings": {
              "bitrate_kbps": 2200,
              "profile": "main"
            }
          },
          "status": "success"
        }
      ]
    },
    "forge_upscaler": {
      "bundle_bytes": 67200000,
      "model_inventory": [
        {
          "role": "playback_upscaler",
          "implementation": "SRVGGNetCompact-v1.0",
          "version": "1.0",
          "size_bytes": 2400000,
          "spdx_license": "BSD-3-Clause",
          "format": "mlpackage"
        },
        {
          "role": "export_upscaler",
          "implementation": "RRDBNet-x4plus-v1.0",
          "version": "1.0",
          "size_bytes": 64800000,
          "spdx_license": "BSD-3-Clause",
          "format": "mlpackage"
        }
      ],
      "tiers": {
        "playback": [
          {
            "clip_id": "general-film-01",
            "input_resolution": "1920x1080",
            "output_resolution": "3840x2160",
            "scale_factor": 2,
            "frame_count": 731,
            "speed": {
              "ms_per_frame_mean": 31.2,
              "ms_per_frame_median": 30.8,
              "ms_per_frame_p95": 34.5,
              "ms_per_frame_p99": 38.1,
              "ms_per_frame_stddev": 1.8,
              "ms_first_frame": 142.0,
              "realtime_factor": 1.34,
              "fps_mean": 32.1
            },
            "quality": {
              "vmaf": 91.8,
              "psnr_db": 32.4,
              "ssim": 0.952,
              "lpips": 0.058
            },
            "memory": {
              "peak_bytes": 1820000000,
              "model_resident_bytes": 2400000
            },
            "status": "success"
          }
        ],
        "export": [
          {
            "clip_id": "general-film-01",
            "input_resolution": "1920x1080",
            "output_resolution": "3840x2160",
            "scale_factor": 2,
            "frame_count": 731,
            "speed": {
              "ms_per_frame_mean": 412.0,
              "ms_per_frame_median": 408.0,
              "ms_per_frame_p95": 445.0,
              "ms_per_frame_p99": 478.0,
              "ms_per_frame_stddev": 14.2,
              "ms_first_frame": 1820.0,
              "realtime_factor": 0.10,
              "fps_mean": 2.4
            },
            "quality": {
              "vmaf": 95.2,
              "psnr_db": 34.8,
              "ssim": 0.971,
              "lpips": 0.032
            },
            "memory": {
              "peak_bytes": 4200000000,
              "model_resident_bytes": 64800000
            },
            "status": "success"
          }
        ]
      }
    }
  },
  "gates": {
    "version": "v1.0",
    "all_passed": false,
    "results": [
      {
        "gate_id": "bundle_size_max",
        "description": "Total .mlpackage bytes in Resources/Models/ (ForgeOptimizer)",
        "comparison": "lte",
        "target": 12000000,
        "actual": 14156800,
        "passed": false
      },
      {
        "gate_id": "throughput_balanced_m4pro_1080p",
        "description": "Realtime factor at 1080p Balanced on M4 Pro, mean over general subset",
        "comparison": "gte",
        "target": 0.7,
        "actual": 1.47,
        "passed": true,
        "hardware_required": "M4 Pro",
        "corpus_subset": "general"
      },
      {
        "gate_id": "vmaf_balanced_min",
        "description": "VMAF at Balanced, mean over all clips",
        "comparison": "gte",
        "target": 90.0,
        "actual": 92.4,
        "passed": true,
        "corpus_subset": "all"
      },
      {
        "gate_id": "compression_balanced_min",
        "description": "Savings vs non-optimized at Balanced, mean over general subset",
        "comparison": "gte",
        "target": 0.35,
        "actual": 0.35,
        "passed": true,
        "corpus_subset": "general"
      },
      {
        "gate_id": "compression_signage_max_min",
        "description": "Savings vs non-optimized at Maximum on signage subset",
        "comparison": "gte",
        "target": 0.55,
        "actual": 0.58,
        "passed": true,
        "corpus_subset": "signage"
      },
      {
        "gate_id": "playback_4k_fps_min",
        "description": "Playback tier fps at 1080p→4K on M4 Pro",
        "comparison": "gte",
        "target": 30.0,
        "actual": 32.1,
        "passed": true,
        "hardware_required": "M4 Pro"
      },
      {
        "gate_id": "quality_regressor_srcc_min",
        "description": "SRCC vs human MOS on signage holdout (only valid after Phase E)",
        "comparison": "gte",
        "target": 0.90,
        "actual": 0.0,
        "passed": false,
        "tolerance": 1.0
      }
    ]
  }
}
```

---

## 4. Swift Codable Types

Drop these into `Packages/ForgeOptimizer/Sources/ForgeOptimizer/Benchmark/`. The harness serializes `BenchmarkReport` to the file path in §1, and the CI tool deserializes it for gate checking.

```swift
import Foundation

// MARK: - Top-level report

public struct BenchmarkReport: Codable, Sendable {
    public let schemaVersion: String
    public let reportID: UUID
    public let timestampUTC: Date
    public let runLabel: String
    public let notes: String?
    public let git: GitInfo
    public let hardware: HardwareInfo
    public let dependencies: Dependencies
    public let corpus: Corpus
    public let pipelineResults: PipelineResults
    public let gates: GateEvaluation

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case reportID = "report_id"
        case timestampUTC = "timestamp_utc"
        case runLabel = "run_label"
        case notes, git, hardware, dependencies, corpus
        case pipelineResults = "pipeline_results"
        case gates
    }
}

// MARK: - Provenance

public struct GitInfo: Codable, Sendable {
    public let sha: String
    public let branch: String
    public let dirty: Bool
    public let remoteURL: URL?

    enum CodingKeys: String, CodingKey {
        case sha, branch, dirty
        case remoteURL = "remote_url"
    }
}

public struct HardwareInfo: Codable, Sendable {
    public let modelIdentifier: String
    public let chip: String
    public let cpuCores: Int?
    public let gpuCores: Int?
    public let memoryGB: Double
    public let osVersion: String
    public let thermalState: ThermalState
    public let onBattery: Bool

    public enum ThermalState: String, Codable, Sendable {
        case nominal, fair, serious, critical
    }

    enum CodingKeys: String, CodingKey {
        case modelIdentifier = "model_identifier"
        case chip
        case cpuCores = "cpu_cores"
        case gpuCores = "gpu_cores"
        case memoryGB = "memory_gb"
        case osVersion = "os_version"
        case thermalState = "thermal_state"
        case onBattery = "on_battery"
    }
}

public struct Dependencies: Codable, Sendable {
    public let mlxVersion: String
    public let mlxSwiftVersion: String
    public let swiftVersion: String
    public let xcodeVersion: String?
    public let ffmpegVersion: String?
    public let coremlRuntime: String?

    enum CodingKeys: String, CodingKey {
        case mlxVersion = "mlx_version"
        case mlxSwiftVersion = "mlx_swift_version"
        case swiftVersion = "swift_version"
        case xcodeVersion = "xcode_version"
        case ffmpegVersion = "ffmpeg_version"
        case coremlRuntime = "coreml_runtime"
    }
}

// MARK: - Corpus

public struct Corpus: Codable, Sendable {
    public let name: String
    public let version: String
    public let clips: [CorpusClip]
}

public struct CorpusClip: Codable, Sendable {
    public let id: String
    public let category: Category
    public let subcategory: String?
    public let resolution: String
    public let frameRate: Double?
    public let durationS: Double
    public let codec: String?
    public let sha256: String

    public enum Category: String, Codable, Sendable {
        case general, signage, legacy
    }

    enum CodingKeys: String, CodingKey {
        case id, category, subcategory, resolution
        case frameRate = "frame_rate"
        case durationS = "duration_s"
        case codec, sha256
    }
}

// MARK: - Pipeline results

public struct PipelineResults: Codable, Sendable {
    public let forgeOptimizer: ForgeOptimizerResults?
    public let forgeUpscaler: ForgeUpscalerResults?

    enum CodingKeys: String, CodingKey {
        case forgeOptimizer = "forge_optimizer"
        case forgeUpscaler = "forge_upscaler"
    }
}

public struct ForgeOptimizerResults: Codable, Sendable {
    public let bundleBytes: Int
    public let modelInventory: [ModelInventoryEntry]
    public let runs: [OptimizerRun]

    enum CodingKeys: String, CodingKey {
        case bundleBytes = "bundle_bytes"
        case modelInventory = "model_inventory"
        case runs
    }
}

public struct ForgeUpscalerResults: Codable, Sendable {
    public let bundleBytes: Int
    public let modelInventory: [ModelInventoryEntry]
    public let tiers: Tiers

    public struct Tiers: Codable, Sendable {
        public let playback: [UpscalerRun]?
        public let export: [UpscalerRun]?
        public let signage: [UpscalerRun]?
    }

    enum CodingKeys: String, CodingKey {
        case bundleBytes = "bundle_bytes"
        case modelInventory = "model_inventory"
        case tiers
    }
}

public struct ModelInventoryEntry: Codable, Sendable {
    public let role: ModelRole
    public let implementation: String
    public let version: String?
    public let sizeBytes: Int
    public let spdxLicense: String
    public let format: ModelFormat?

    public enum ModelRole: String, Codable, Sendable {
        case restoration, denoise
        case artifactRemoval = "artifact_removal"
        case superResolution2x = "super_resolution_2x"
        case superResolution4x = "super_resolution_4x"
        case saliency
        case qualityRegressor = "quality_regressor"
        case guidedFilter = "guided_filter"
        case playbackUpscaler = "playback_upscaler"
        case exportUpscaler = "export_upscaler"
        case signageUpscaler = "signage_upscaler"
        case opticalFlow = "optical_flow"
    }

    public enum ModelFormat: String, Codable, Sendable {
        case mlpackage, safetensors, mlmodelc
    }

    enum CodingKeys: String, CodingKey {
        case role, implementation, version
        case sizeBytes = "size_bytes"
        case spdxLicense = "spdx_license"
        case format
    }
}

// MARK: - Runs

public struct OptimizerRun: Codable, Sendable {
    public let clipID: String
    public let optimizationLevel: OptimizationLevel
    public let resolution: String
    public let frameCount: Int?
    public let speed: SpeedMetrics?
    public let quality: QualityMetrics?
    public let memory: MemoryMetrics?
    public let compression: CompressionMetrics?
    public let status: RunStatus
    public let failureReason: String?

    public enum OptimizationLevel: String, Codable, Sendable {
        case off, light, balanced, aggressive, maximum
    }

    enum CodingKeys: String, CodingKey {
        case clipID = "clip_id"
        case optimizationLevel = "optimization_level"
        case resolution
        case frameCount = "frame_count"
        case speed, quality, memory, compression, status
        case failureReason = "failure_reason"
    }
}

public struct UpscalerRun: Codable, Sendable {
    public let clipID: String
    public let inputResolution: String
    public let outputResolution: String
    public let scaleFactor: Int?
    public let frameCount: Int?
    public let speed: SpeedMetrics?
    public let quality: QualityMetrics?
    public let memory: MemoryMetrics?
    public let textMetrics: TextMetrics?
    public let status: RunStatus
    public let failureReason: String?

    enum CodingKeys: String, CodingKey {
        case clipID = "clip_id"
        case inputResolution = "input_resolution"
        case outputResolution = "output_resolution"
        case scaleFactor = "scale_factor"
        case frameCount = "frame_count"
        case speed, quality, memory
        case textMetrics = "text_metrics"
        case status
        case failureReason = "failure_reason"
    }
}

public enum RunStatus: String, Codable, Sendable {
    case success, partial, failed
}

// MARK: - Metrics

public struct SpeedMetrics: Codable, Sendable {
    public let msPerFrameMean: Double
    public let msPerFrameMedian: Double
    public let msPerFrameP95: Double
    public let msPerFrameP99: Double
    public let msPerFrameStddev: Double
    public let msFirstFrame: Double?
    public let realtimeFactor: Double
    public let fpsMean: Double?

    enum CodingKeys: String, CodingKey {
        case msPerFrameMean = "ms_per_frame_mean"
        case msPerFrameMedian = "ms_per_frame_median"
        case msPerFrameP95 = "ms_per_frame_p95"
        case msPerFrameP99 = "ms_per_frame_p99"
        case msPerFrameStddev = "ms_per_frame_stddev"
        case msFirstFrame = "ms_first_frame"
        case realtimeFactor = "realtime_factor"
        case fpsMean = "fps_mean"
    }
}

public struct QualityMetrics: Codable, Sendable {
    public let vmaf: Double?
    public let vmafNeg: Double?
    public let psnrDB: Double?
    public let ssim: Double?
    public let msSSIM: Double?
    public let lpips: Double?
    public let siglip2IQA: Double?

    enum CodingKeys: String, CodingKey {
        case vmaf
        case vmafNeg = "vmaf_neg"
        case psnrDB = "psnr_db"
        case ssim
        case msSSIM = "ms_ssim"
        case lpips
        case siglip2IQA = "siglip2_iqa"
    }
}

public struct MemoryMetrics: Codable, Sendable {
    public let peakBytes: Int
    public let steadyStateBytes: Int?
    public let modelResidentBytes: Int?

    enum CodingKeys: String, CodingKey {
        case peakBytes = "peak_bytes"
        case steadyStateBytes = "steady_state_bytes"
        case modelResidentBytes = "model_resident_bytes"
    }
}

public struct CompressionMetrics: Codable, Sendable {
    public let inputBytes: Int
    public let outputBytes: Int
    public let ratioVsBaseline: Double?
    public let savingsVsBaseline: Double?
    public let encoder: String?
    public let encoderSettings: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case inputBytes = "input_bytes"
        case outputBytes = "output_bytes"
        case ratioVsBaseline = "ratio_vs_baseline"
        case savingsVsBaseline = "savings_vs_baseline"
        case encoder
        case encoderSettings = "encoder_settings"
    }
}

public struct TextMetrics: Codable, Sendable {
    public let ocrAccuracy: Double?
    public let ocrWordAccuracy: Double?
    public let edgeSharpness: Double?

    enum CodingKeys: String, CodingKey {
        case ocrAccuracy = "ocr_accuracy"
        case ocrWordAccuracy = "ocr_word_accuracy"
        case edgeSharpness = "edge_sharpness"
    }
}

// MARK: - Gates

public struct GateEvaluation: Codable, Sendable {
    public let version: String
    public let allPassed: Bool?
    public let results: [GateResult]

    enum CodingKeys: String, CodingKey {
        case version
        case allPassed = "all_passed"
        case results
    }
}

public struct GateResult: Codable, Sendable {
    public let gateID: String
    public let description: String
    public let comparison: Comparison
    public let target: Double
    public let actual: Double
    public let passed: Bool
    public let hardwareRequired: String?
    public let corpusSubset: CorpusSubset?
    public let tolerance: Double?

    public enum Comparison: String, Codable, Sendable {
        case lte, gte, eq, lt, gt
    }

    public enum CorpusSubset: String, Codable, Sendable {
        case general, signage, legacy, all
    }

    enum CodingKeys: String, CodingKey {
        case gateID = "gate_id"
        case description, comparison, target, actual, passed
        case hardwareRequired = "hardware_required"
        case corpusSubset = "corpus_subset"
        case tolerance
    }
}

// MARK: - Helpers

/// A type-erased Codable wrapper for the freeform encoder_settings field.
public struct AnyCodable: Codable, Sendable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self.value = v }
        else if let v = try? container.decode(Int.self) { self.value = v }
        else if let v = try? container.decode(Double.self) { self.value = v }
        else if let v = try? container.decode(String.self) { self.value = v }
        else if let v = try? container.decode([AnyCodable].self) { self.value = v }
        else if let v = try? container.decode([String: AnyCodable].self) { self.value = v }
        else { self.value = NSNull() }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [AnyCodable]: try container.encode(v)
        case let v as [String: AnyCodable]: try container.encode(v)
        default: try container.encodeNil()
        }
    }
}
```

---

## 5. Gate Catalog

These match Forge-CodingPlan-v1.0 §4. The harness should emit a `GateResult` for every entry below on every run, even if `actual` is zero or the gate isn't yet applicable (e.g. `quality_regressor_srcc_min` before Phase E). This keeps the CI diff stable across the project lifecycle.

> **Catalog reduced to 5 gates (ADR-0009).** The two realtime throughput gates
> — `throughput_balanced_m4pro_1080p` and `playback_4k_fps_min` — were
> **removed**: realtime is a separate-project concern, not a Forge requirement.
> The `realtime_factor` / `fps_mean` fields are still emitted as **informational**
> metrics (just not gated). The struck rows below are retained for historical
> baseline-diff context only.

| `gate_id` | Description | Comparison | Target | Hardware | Corpus subset |
|---|---|---|---|---|---|
| `bundle_size_max` | Total `.mlpackage` bytes in `Resources/Models/` (ForgeOptimizer) | `lte` | 12000000 | any | n/a |
| ~~`throughput_balanced_m4pro_1080p`~~ | ~~Realtime factor at 1080p Balanced~~ — REMOVED (ADR-0009) | — | — | — | — |
| `vmaf_balanced_min` | VMAF at Balanced, mean over all clips | `gte` | 90.0 | any | all |
| `compression_balanced_min` | Savings vs non-optimized at Balanced | `gte` | 0.35 | any | general |
| `compression_signage_max_min` | Savings vs non-optimized at Maximum (signage) | `gte` | 0.55 | any | signage |
| ~~`playback_4k_fps_min`~~ | ~~Playback tier fps at 1080p→4K~~ — REMOVED (ADR-0009) | — | — | — | — |
| `quality_regressor_srcc_min` | SRCC vs human MOS (Phase E.5+) | `gte` | 0.90 | any | all |

---

## 6. CI Integration Sketch

```bash
# In CI after `xcodebuild test`:
xcrun swift run forge-benchmark-runner \
    --corpus Forge/Tests/Corpus \
    --output benchmark-${RUN_LABEL}-$(git rev-parse --short HEAD).json \
    --hardware-target "M4 Pro"

xcrun swift run forge-gate-checker \
    --report benchmark-${RUN_LABEL}-$(git rev-parse --short HEAD).json \
    --baseline benchmark-baseline-v0.3-mlx-0.31.2-a1b2c3d.json \
    --fail-on regression
```

The `--fail-on regression` flag treats any gate transitioning from `passed: true` (baseline) to `passed: false` (current) as a CI failure. New gates that haven't passed before are warnings, not failures. This prevents one-off blocked gates (like `quality_regressor_srcc_min` pre-Phase-E) from breaking the whole pipeline.

---

End of schema document.
