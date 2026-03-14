# Gaze-Driven Video Encoding (QP Map Generation) (Sec 3.3)

This document explains the Gaze-Driven Video Encoding mechanism, which optimizes video bitrate by allocating visual quality based on the user's gaze.

## Concept

Traditional video encoding allocates bitrate uniformly or based on image complexity. EyeNexus uses **Non-uniform Quantization** aligned with the Human Visual System (HVS). We generate a Quantization Parameter (QP) map where:
*   **Foveal Region:** Low QP (high quality, low compression).
*   **Peripheral Region:** High QP (lower quality, high compression).

This is implemented using NVIDIA NVENC's `QP_MAP_DELTA` mode (or `CONSTQP` mode with offsets).

## Mathematical Model

### 1. Gaze to Macroblock Mapping
First, the gaze point $(X_r, Y_r)$ in the FSC frame is mapped to the macroblock coordinate system. Each macroblock is $16 \times 16$ pixels.

$$
X_{QP} = \lceil X_r / 16 \rceil, \quad Y_{QP} = \lceil Y_r / 16 \rceil
$$

### 2. Gaussian Quality Assignment (QO with variance and fixation confidence)

We model the quality falloff as a 2D Gaussian function centered at the gaze macroblock $(X_{QP}, Y_{QP})$. For any macroblock $(i, j)$, the Quantization Offset (QO) is calculated using an **effective** spread parameter $C_{eff}$ that combines network feedback with gaze variance and fixation confidence:

$$
QO(i, j) = QO_{max} - QO_{max} \times \exp\left(-\frac{(Distance(i, j))^2}{2\,C_{eff}^2}\right)
$$

Where:
*   $Distance(i, j) = \sqrt{(i - X_{QP})^2 + (j - Y_{QP})^2}$ is the Euclidean distance from the gaze center (in macroblock units).
*   $QO_{max}$ (code: `MAX_QP_OFFSET`): The maximum quantization offset allowed.
*   $C_{eff}$: The **effective foveation spread**, which determines the width of the high-quality region. It is computed from the network-driven controller $C_{network}$, gaze variance, and optional fixation confidence (see below).

#### Effective spread $C_{eff}$

$C_{eff}$ is computed in Rust (`alvr/server/src/congestion_controller.rs::compute_c_effective`) and passed to the encoder. It is clamped to $[C_{min}, C_{max}]$ (e.g. 2 and 80) so that network congestion can still shrink the fovea.

1. **Base value from network**: $C_{network}$ (called `controller_c`) comes from the congestion controller (AIMD / trendline).

2. **Gaze variance term** (optional): If gaze variance magnitude $\sigma^2$ (e.g. in pixel²) is available from a sliding window of recent gaze samples:
   * Define normalized variance:
     $$n = \begin{cases} 0 & \sigma^2 \leq \sigma^2_{low} \\ 1 & \sigma^2 \geq \sigma^2_{high} \\ \frac{\sigma^2 - \sigma^2_{low}}{\sigma^2_{high} - \sigma^2_{low}} & \text{otherwise} \end{cases}$$
     with $\sigma^2_{low} = 100$, $\sigma^2_{high} = 10\,000$ (constants `GAZE_VARIANCE_LOW`, `GAZE_VARIANCE_HIGH`).
   * Let $\Delta = (2n - 1)\, \Delta_{max}$ (e.g. $\Delta_{max} = 15$, `GAZE_C_DELTA`). So low variance (fixation) gives $\Delta < 0$ (tighter fovea), high variance gives $\Delta > 0$ (wider fovea).
   * $C_1 = \mathrm{clamp}(C_{network} + \Delta;\ C_{min},\ C_{max})$.

3. **Fixation confidence term** (optional): If the device (or a proxy) provides fixation confidence $f \in [0,1]$:
   * Scale: $s = 1 - w_f \cdot f$ with $w_f = 0.15$ (`FIXATION_CONFIDENCE_WEIGHT`). High confidence (stable fixation) reduces the spread.
   * $C_{eff} = \mathrm{clamp}(C_1 \cdot s;\ C_{min},\ C_{max})$.
   If confidence is not available ($f < 0$ or missing), $C_{eff} = C_1$.

**Summary**: High gaze variance (looking around) increases $C_{eff}$ (wider, softer fovea); low variance and high fixation confidence decrease $C_{eff}$ (tighter fovea, more aggressive peripheral compression). **Predictive Gaussian:** if gaze variance or gaze velocity is above a threshold, $C_{eff}$ is further increased by a fixed delta (capped at $C_{max}$) so that the region that might become the next fovea is already higher quality; see [GAZE_CONTINGENT_RATE_CONTROL.md](GAZE_CONTINGENT_RATE_CONTROL.md). The encoder uses $C_{eff}$ in the Gaussian in `NvEncoder.cpp` (`EyeNexus_CalculateQPOffsetValue_*`); the C++ layer receives $C_{eff}$ via `FfiEyeNexusEncoderParams.c_effective`. Parameters `gaze_variance` and `fixation_confidence` are also passed for logging and for possible future use (e.g. a multiplicative factor on QO). For the definition, rationale, and literature supporting fixation confidence, see [FIXATION_CONFIDENCE.md](FIXATION_CONFIDENCE.md).

## Implementation

The logic is located in `alvr/server/cpp/platform/win32/NvEncoder.cpp`:

*   **Function:** `GenQPDeltaMap`
*   **Process:**
    1.  Initializes the `qp_map` array.
    2.  Iterates through every macroblock $(i, j)$ in the frame.
    3.  Calls `EyeNexus_CalculateQPOffsetValue_leftEye` (and `_rightEye`) with $C_{eff}$ to compute the Gaussian-based QP offset (see the QO equation above). $C_{eff}$ is supplied via `FfiEyeNexusEncoderParams.c_effective` from the Rust server (which combines network C, gaze variance, and fixation confidence).
    4.  Selects the minimum QP (best quality) if the macroblock falls within the influence of both eyes (relevant for stereo overlapping regions).
    5.  Passes the generated `qp_map` to the NVENC encoder via `NV_ENC_PIC_PARAMS`.

### Foveation Controller (C) and $C_{eff}$
The spread parameter is $C_{eff}$ (effective C). It is derived from the network-driven controller $C$ (from the congestion controller) and optionally from gaze variance and fixation confidence. A larger $C_{eff}$ expands the high-quality region (e.g. when the user is looking around or network is good); a smaller $C_{eff}$ shrinks it (stable fixation or poor network), saving bitrate. See the $C_{eff}$ formulas above.

## Encoder Configuration

To enable foveated encoding, the NVENC encoder must be configured specifically to accept external QP maps and use a constant base QP. This configuration is handled in `alvr/server/cpp/platform/win32/VideoEncoderNVENC.cpp`.

### Key Settings

1.  **Rate Control Mode:** `NV_ENC_PARAMS_RC_CONSTQP`
    *   Disables automatic bitrate targeting.
    *   Uses a fixed base QP for the entire frame, which we then modify per-block.

2.  **QP Map Mode:** `NV_ENC_QP_MAP_DELTA`
    *   Tells the encoder to interpret the provided map as *offsets* (deltas) from the base QP, rather than absolute QP values.
    *   This allows for smoother gradients and easier relative quality control.

3.  **Base QP:** `rcParams.constQP = {23, 23, 23}`
    *   Sets the baseline quality (e.g., QP=23) for I, P, and B frames.
    *   The Gaussian function calculates positive offsets to *increase* QP (reduce quality) in the periphery relative to this base.

4.  **Disable Automatic Features:**
    *   `enableAQ = 0` (Spatial Adaptive Quantization disabled to avoid conflict with our map).
    *   `enableTemporalAQ = 0` (Temporal Adaptive Quantization disabled).

### Code Reference

```cpp
// EyeNexus-Gaze-Driven Video Encoding: Setup NVENC for Constant QP mode with Delta Map
encodeConfig.rcParams.qpMapMode = NV_ENC_QP_MAP_DELTA;
encodeConfig.rcParams.enableAQ = 0;
encodeConfig.rcParams.enableTemporalAQ = 0;
encodeConfig.rcParams.rateControlMode = NV_ENC_PARAMS_RC_CONSTQP;
encodeConfig.rcParams.constQP = {23, 23, 23}; 
```
