# Gaze-Contingent Rate Control (AIMD) (Sec 3.6)

EyeNexus uses a novel rate control mechanism that adjusts the **Foveation Controller ($C$)** instead of directly setting a bitrate target. This $C$ value controls the spread of the high-quality foveal region in the video encoder.

## Foveation Controller ($C$)

*   **High $C$:** Large foveal region (high quality, high bitrate).
*   **Low $C$:** Small foveal region (lower quality periphery, low bitrate).
*   **Range:** $C_{min}$ to $C_{max}$ (Resolution dependent).

## AIMD Algorithm

We use an **Additive Increase, Multiplicative Decrease (AIMD)** algorithm to adapt $C$ based on the network state detected by the Network Monitoring module.

### 1. Additive Increase (Normal / Underuse)
When the network is stable or underused (bandwidth is available), we slowly increase $C$ to improve visual quality.

$$
C_{new} = C_{old} + \alpha
$$

*   $\alpha = 0.1$ or $0.2$ (depending on link capacity estimate).

### 2. Multiplicative Decrease (Overuse)
When congestion is detected ($\nabla D > \gamma_{delay}$), we quickly reduce $C$ to relieve network pressure.

$$
C_{new} = C_{old} \times \beta
$$

*   $\beta = 0.9$ (Standard congestion).

### 3. Timeout Decrease
If a feedback timeout occurs (severe congestion), we apply a sharper decrease.

$$
C_{new} = C_{old} \times \beta_t
$$

*   $\beta_t = 0.85$.

## Implementation

The core logic resides in `alvr/server/src/congestion_controller.rs`:

*   **Struct:** `EyeNexus_Controller`
*   **Function:** `Update`
    *   Updates trendline.
    *   Determines state (Normal, Overusing).
    *   Applies AIMD to `controller_c`.
    *   Clamps `controller_c` between 2.0 and 80.0.

The timeout logic is handled in `alvr/server/src/lib.rs` inside `get_controller_c`.

## C_effective: Gaze variance and fixation confidence

The value passed to the encoder is **C_effective** = f(controller_c, gaze_variance, fixation_confidence), not raw `controller_c`. This keeps the fovea size aligned with gaze behavior:

*   **High gaze variance** (looking around): C_effective is increased (wider fovea, less aggressive periphery compression), within [C_min, C_max].
*   **Low gaze variance** (fixation): C_effective is decreased (tighter fovea, more aggressive periphery compression).
*   **Fixation confidence** (when available): From the eye tracker device API, or approximated as 1/(1+variance) when not provided. High confidence (stable fixation) further reduces C_effective (tighter fovea); low or unavailable leaves the variance-based value unchanged.
*   **No gaze data**: C_effective = controller_c (no change).

Implementation: `congestion_controller::compute_c_effective(controller_c, gaze_variance_magnitude, fixation_confidence)` in `alvr/server/src/congestion_controller.rs`; called from `get_controller_c()` and `get_eyenexus_encoder_params()` in `lib.rs`. Fixation confidence is taken from the device when the client sends it (e.g. OpenXR), otherwise from the proxy. C_effective is clamped to [C_min, C_max] so network congestion can still reduce quality.

**Fixation confidence (definition, rationale, and sources):** See [FIXATION_CONFIDENCE.md](FIXATION_CONFIDENCE.md) for a full description, perceptual justification, and references for use in reports and papers.

### Predictive Gaussian (smooth ramp)

When gaze is moving (high variance or high velocity), C_effective is **additionally** increased so that the region that might become the next fovea is already encoded with better quality (pre-emptive widening). This reduces noticeable quality changes after a saccade.

The predictive delta uses a **smooth linear ramp** between low and high thresholds (not a binary step). Variance and velocity each produce a ramp factor in [0, 1]; the larger factor drives the delta:

$$
\text{var\_factor} = \text{clamp}\!\left(\frac{V - V_{\text{low}}}{V_{\text{high}} - V_{\text{low}}},\; 0,\; 1\right)
\qquad
\text{vel\_factor} = \text{clamp}\!\left(\frac{u - u_{\text{low}}}{u_{\text{high}} - u_{\text{low}}},\; 0,\; 1\right)
$$

$$
\delta_{\text{pred}} = \Delta C_{\max} \times \max(\text{var\_factor},\; \text{vel\_factor})
$$

$$
C_{\text{effective}} = \min(C_{\text{effective}} + \delta_{\text{pred}},\; C_{\max})
$$

*   **Gaze velocity:** Euclidean distance between the last two gaze samples (pixels per sample), from the gaze history in the server.
*   **Effect:** Wider Gaussian for the next frame(s) when the user is saccading or looking around, so the "new" fovea is already slightly higher quality. The smooth ramp produces a gradual transition rather than a sharp on/off switch.

### Latency-aware capping of predictive Gaussian

To avoid adding excessive decode latency when the predictive Gaussian widens the fovea (larger frames), the predictive delta is **suppressed** when decode latency exceeds a baseline by more than a budget:

*   **Budget:** `PREDICTIVE_LATENCY_BUDGET_MS` (1.5 ms) in `congestion_controller.rs` — maximum additional decode latency allowed from predictive widening.
*   **Baseline:** EWMA of recent decode latencies (from client `video_decode`) when predictive widening was **not** applied; updated in `lib.rs` whenever `compute_c_effective` returns `predictive_delta_was_applied == false`.
*   **Rule:** If current decode latency > baseline + `PREDICTIVE_LATENCY_BUDGET_MS`, the predictive delta is not applied (C_effective is unchanged by the predictive step). This creates a feedback loop: widen → if decode latency spikes → back off.
*   **Data flow:** Client stats → `BitrateManager::report_frame_latencies` (stores last decode latency) → `get_last_decode_latency_ms()` → `compute_c_effective(last_decode_latency_ms, decode_latency_baseline_ms)`.

### Design note: High motion / saccade → less sensitivity to fine detail

When gaze is unstable (high variance, saccades, or post-saccadic motion), the human visual system is less sensitive to fine spatial detail. We therefore use **high gaze variance** to increase C_effective (wider fovea, less aggressive periphery compression), and **low variance** (stable fixation) to decrease C_effective (tighter fovea, more aggressive periphery). This keeps perceived quality aligned with what the user can actually resolve:

*   **During saccades:** Contrast sensitivity is suppressed (saccadic suppression); devoting extra bitrate to a narrow fovea is less beneficial.
*   **During fixation:** The user can resolve fine detail in the fovea; a tight fovea with stronger periphery compression is perceptually acceptable and saves bitrate.
*   **Periphery vs fovea:** Perceptual sensitivity drops with eccentricity; periphery can be compressed more when the user is not rapidly shifting gaze.

**References (for related work and method justification):**

*   **Li et al.** — "Visual attention guided bit allocation in video compression," *Image and Vision Computing* 29(1), 2011 (EWPSNR; perception/attention during motion).
*   **Rimac-Drlje et al.** — "Foveation-based content Adaptive Structural Similarity index," 2011 18th International Conference on Systems, Signals and Image Processing (EWSSIM / foveation-based quality).
*   **Saccadic suppression** — e.g. "Motion perception during saccadic eye movements," *Nature Neuroscience* 2000; contrast sensitivity suppressed during saccades.
*   **Post-saccadic perception** — "Selective postsaccadic enhancement of motion perception," *Vision Research* (ScienceDirect); post-saccade sensitivity changes.
*   **Strasburger et al.** — Peripheral vision and pattern recognition (e.g. *Journal of Vision*); supports periphery vs fovea sensitivity (cited in EyeNexus Appendix B).

## Feature toggles (ablation)

Each gaze feature can be disabled independently for ablation studies. Constants in `alvr/server/src/congestion_controller.rs`:

| Toggle constant | Default | Effect when **true** | Effect when **false** |
|---|---|---|---|
| `ENABLE_GAZE_VARIANCE_MODULATION` | `true` | C_effective is modulated by gaze variance (high variance → larger C, low → smaller C). | C_effective is not adjusted by variance; only network `controller_c` feeds into the fixation/predictive steps. |
| `ENABLE_FIXATION_CONFIDENCE` | `true` | `fixation_confidence` scales C_effective down (high confidence → tighter fovea). | Fixation confidence is ignored; C_effective is unchanged by confidence. |
| `ENABLE_PREDICTIVE_GAUSSIAN` | `true` | Predictive widening is applied when gaze variance/velocity is high. | No predictive delta is added; C_effective does not widen pre-emptively during saccades. |

**Recommended ablation configurations:**

| Configuration | Variance | Fixation | Predictive | Purpose |
|---|---|---|---|---|
| Baseline | OFF | OFF | OFF | Pure network-driven C (no gaze) |
| Variance only | ON | OFF | OFF | Measure variance modulation in isolation |
| Variance + Fixation | ON | ON | OFF | Measure fixation confidence on top of variance |
| Full EyeNexus | ON | ON | ON | All gaze features active |

Evaluation scripts can read the active configuration from the **statistics_mtp.csv** metadata row: the second row has first column `#eyenexus_toggles` and the next three columns are 1/0 for the three toggles (gaze_variance_modulation, fixation_confidence, predictive_gaussian). Skip rows where the first column starts with `#` when loading data rows.

## Constants reference

All tunable constants live in `alvr/server/src/congestion_controller.rs`. The table below lists every constant, its value, units, and role.

### Foveation controller bounds

| Constant | Value | Units | Description |
|---|---|---|---|
| `C_MIN` | 2.0 | — | Minimum foveation controller C (tightest possible fovea). Also the AIMD lower clamp. |
| `C_MAX` | 80.0 | — | Maximum foveation controller C (widest possible fovea). Also the AIMD upper clamp. |

### Gaze variance modulation

These control how gaze variance maps to the additive C delta when `ENABLE_GAZE_VARIANCE_MODULATION` is true.

| Constant | Value | Units | Description |
|---|---|---|---|
| `GAZE_VARIANCE_LOW` | 100.0 | pixel² | Variance below this is treated as stable fixation (normalized factor = 0). |
| `GAZE_VARIANCE_HIGH` | 10 000.0 | pixel² | Variance at or above this is treated as full high-motion (normalized factor = 1). |
| `GAZE_C_DELTA` | 15.0 | C units | Maximum additive/subtractive swing from gaze variance. At normalized = 0.5 (midpoint), delta = 0; at 0 → −15; at 1 → +15. Formula: `delta = (2 * normalized − 1) * GAZE_C_DELTA`. |

The normalized factor is linearly interpolated between `GAZE_VARIANCE_LOW` and `GAZE_VARIANCE_HIGH`:

$$
\text{normalized} = \text{clamp}\!\left(\frac{V - V_{\text{low}}}{V_{\text{high}} - V_{\text{low}}},\; 0,\; 1\right)
$$

### Fixation confidence

| Constant | Value | Units | Description |
|---|---|---|---|
| `FIXATION_CONFIDENCE_WEIGHT` | 0.15 | — | At confidence = 1.0 (strong fixation), C_effective is scaled by `1 − 0.15 = 0.85` (15 % reduction, tighter fovea). At confidence = 0, no change. Intermediate values interpolate linearly. |

### Predictive Gaussian thresholds

These control the smooth linear ramp that produces the predictive widening delta when `ENABLE_PREDICTIVE_GAUSSIAN` is true.

| Constant | Value | Units | Description |
|---|---|---|---|
| `PREDICTIVE_VARIANCE_LOW` | 1 000.0 | pixel² | Variance below this contributes no predictive widening (ramp factor = 0). |
| `PREDICTIVE_VARIANCE_HIGH` | 5 000.0 | pixel² | Variance at or above this produces full predictive widening (ramp factor = 1). |
| `PREDICTIVE_VELOCITY_LOW` | 10.0 | px/sample | Velocity below this contributes no predictive widening (ramp factor = 0). |
| `PREDICTIVE_VELOCITY_HIGH` | 30.0 | px/sample | Velocity at or above this produces full predictive widening (ramp factor = 1). |
| `PREDICTIVE_C_DELTA_MAX` | 8.0 | C units | Maximum extra C added by the predictive step. The ramp factor (0–1) scales this. |

### Latency budget

| Constant | Value | Units | Description |
|---|---|---|---|
| `PREDICTIVE_LATENCY_BUDGET_MS` | 1.5 | ms | Maximum additional decode latency (above baseline EWMA) tolerated from predictive widening. When exceeded, the predictive delta is suppressed entirely until decode latency returns within budget. |

### AIMD parameters (in `EyeNexus_Controller::Update`)

| Parameter | Value | Description |
|---|---|---|
| Additive increase α | 0.1 or 0.2 | 0.1 when link capacity is estimated, 0.2 otherwise. |
| Multiplicative decrease β | 0.9 | Applied on overuse detection. |
| Timeout decrease β_t | 0.85 | Applied on feedback timeout (in `lib.rs`). |
| Controller C initial | 188.0 | Starting value; clamped to [C_MIN, C_MAX] after first update. |

### QP map recomputation trigger (C++ side)

In `alvr/server/cpp/platform/win32/NvEncoder.cpp`, the QP delta map is recomputed when **either** the gaze macroblock position changes **or** `|c_effective − prev_c_effective| > C_EFF_CHANGE_THRESHOLD` (1.0). This ensures C_effective changes from the predictive ramp or latency-cap feedback are reflected in the encoder even when gaze position is stationary. The previous C_effective is stored as `m_prev_c_effective` in `NvEncoder.h`.

## CSV logging for analysis

Gaze and gaze-variance data are written to CSVs in the same directory as other EyeNexus logs (e.g. SteamVR driver log directory, depending on process CWD):

*   **eyegaze.csv** (per gaze sample): `target_ts`, `leftx`, `lefty`, `rightx`, `righty`, `gaze_var_x`, `gaze_var_y`, `gaze_variance_magnitude`. Variance is computed over the sliding window (see gaze history); empty when &lt; 2 samples.
*   **statistics_mtp.csv** (per frame): same columns as before, plus `gaze_variance_magnitude` for frame-level analysis and plots. The second row is a metadata line: first column `#eyenexus_toggles`, then three columns (1/0) for the feature toggles above.
