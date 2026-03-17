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

## Fixation-Confidence Fovea (demo tuning)

When **fixation-confidence** is enabled, the foveal spread is modulated by gaze stability: stable gaze (low variance) increases effective $C$ (larger fovea), and noisy gaze decreases it. This is in addition to the network AIMD controller $C$.

*   **Normal mode (default):** Set `fixation_confidence_exaggeration` to `1.0` for a subtle effect suitable for production.
*   **Demo mode:** Increase `fixation_confidence_exaggeration` to make fovea-size changes more visible for demos:
    *   **Mild:** `1.5`
    *   **Clear:** `2.0`
    *   **Very obvious:** `2.5` (staged demos only; may affect quality stability).

**Expected effect:** The high-quality foveal region expands when you hold a fixation (high confidence) and contracts when gaze is moving (low confidence). Use **statistics_mtp.csv** columns `fixation_confidence` and `c_effective` to validate and tune live.

## CSV logging for analysis

Gaze and gaze-variance data are written to CSVs in the same directory as other EyeNexus logs (e.g. SteamVR driver log directory, depending on process CWD):

*   **eyegaze.csv** (per gaze sample): `target_ts`, `leftx`, `lefty`, `rightx`, `righty`, `gaze_var_x`, `gaze_var_y`, `gaze_variance_magnitude`. Variance is computed over the sliding window (see gaze history); empty when &lt; 2 samples.
*   **statistics_mtp.csv** (per frame): latency and bitrate columns, plus `C`, `gaze_variance_magnitude`, `fixation_confidence`, and `c_effective` for frame-level analysis and demo tuning. When fixation-confidence is disabled, `fixation_confidence` is empty and `c_effective` equals `C`.
