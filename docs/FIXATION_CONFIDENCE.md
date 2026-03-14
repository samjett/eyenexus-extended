# Fixation Confidence in Gaze-Contingent Encoding

This document defines **fixation confidence**, explains its role in EyeNexus foveated rate control, and backs the design with perceptual and eye-tracking literature. It is intended to support discussion in technical reports and papers.

---

## 1. Definitions

### 1.1 Fixation

A **fixation** is a period during which the eyes are relatively stationary and the viewer is actively processing visual information at the point of regard. Fixations are interspersed with **saccades**—rapid, ballistic eye movements that shift gaze from one location to another. In eye-tracking literature, fixations are typically identified using velocity thresholds (e.g. dispersion or velocity-based algorithms): when gaze velocity falls below a threshold and remains stable for a minimum duration, the episode is classified as a fixation [1, 2].

### 1.2 Fixation confidence

**Fixation confidence** is a scalar (e.g. in \([0, 1]\)) that indicates how reliably the current gaze state can be treated as a stable fixation. High confidence means the user is likely fixating at the reported point with low uncertainty; low confidence means gaze may be in transition (e.g. during or just after a saccade) or that the eye-tracker signal is noisy. In VR headsets, confidence can be provided by the device API when supported (e.g. from internal fixation-detection or signal-quality metrics), or it can be **approximated** from gaze stability over a short time window—stable gaze implies high “confidence” that the user is fixating [1, 3].

---

## 2. Why fixation confidence matters for foveated encoding

In gaze-contingent foveated encoding, we allocate more bits (lower QP) near the current gaze point and fewer bits in the periphery. Two perceptual arguments justify using fixation confidence to modulate the **effective foveation spread** (\(C_{\mathrm{eff}}\)):

### 2.1 Perception is sharper during fixation

During a **fixation**, the visual system is tuned to process fine detail at the fovea. When the user is **not** fixating—e.g. during a saccade or in a brief post-saccadic period—sensitivity to fine spatial detail is reduced. This is related to **saccadic suppression**: contrast sensitivity and the ability to resolve detail are temporarily reduced during (and sometimes around) saccades [4, 5]. Therefore:

- **High fixation confidence** (user is clearly fixating) → we can afford a **tighter** high-quality region (smaller \(C_{\mathrm{eff}}\)) and compress the periphery more aggressively, because the user is able to appreciate fine detail only at the fovea.
- **Low fixation confidence** (gaze moving or uncertain) → we use a **wider** high-quality region (larger \(C_{\mathrm{eff}}\)) so that the area that might become the next fixation, or the current uncertain fixation point, is already encoded with sufficient quality; this avoids visible quality drops when perception is less sensitive.

### 2.2 Attention and bit allocation

Visual attention is closely tied to fixation: attended regions tend to be fixated, and fixation locations are strong predictors of where viewers allocate attention [6]. Perceptual quality metrics that weight by gaze (e.g. **EWPSNR** [6], **foveated SSIM** [7]) assume that quality at the fixation point matters most. Using fixation confidence to tighten the fovea when the user is clearly fixating is consistent with this: we concentrate bits where attention (and thus perceived quality) is highest, and rely on reduced peripheral sensitivity [8] to allow stronger compression away from the gaze point.

---

## 3. Implementation in EyeNexus

### 3.1 Sources of fixation confidence

1. **Device API (when available)**  
   If the eye tracker or runtime (e.g. OpenXR) exposes a fixation or gaze-confidence value, the client sends it to the server. The server stores it and uses it when computing \(C_{\mathrm{eff}}\). As of this writing, the OpenXR eye gaze interaction extension does not standardise a confidence field; when runtimes add it, EyeNexus can use it without changing the pipeline.

2. **Proxy from gaze variance (when device confidence is absent)**  
   We maintain a sliding window of recent gaze samples (see gaze history / variance in [GAZE_CONTINGENT_RATE_CONTROL.md](GAZE_CONTINGENT_RATE_CONTROL.md)). When the **variance** of gaze position over this window is **low**, gaze is stable → we treat this as high fixation confidence. When variance is **high**, gaze is moving or unstable → low fixation confidence. We use the proxy:
   \[
   f_{\mathrm{proxy}} = \frac{1}{1 + \sigma^2}
   \]
   (clamped to at most 1), where \(\sigma^2\) is a scalar variance magnitude (e.g. \(\mathrm{var}_x + \mathrm{var}_y\)) in a suitable unit (e.g. pixel²). So: **stable gaze ⇒ high \(f_{\mathrm{proxy}}\) ⇒ high fixation confidence**; **unstable gaze ⇒ low \(f_{\mathrm{proxy}}\) ⇒ low fixation confidence**.

### 3.2 How fixation confidence is used in \(C_{\mathrm{eff}}\)

The effective foveation spread \(C_{\mathrm{eff}}\) is computed in `alvr/server/src/congestion_controller.rs` by `compute_c_effective(controller_c, gaze_variance_magnitude, fixation_confidence)`:

1. A **base** value is obtained from the network-driven controller \(C\) and (optionally) gaze variance: low variance reduces the spread (tighter fovea), high variance increases it (wider fovea). See [GAZE_CONTINGENT_RATE_CONTROL.md](GAZE_CONTINGENT_RATE_CONTROL.md) and [VIDEO_ENCODING_QP.md](VIDEO_ENCODING_QP.md).

2. If **fixation confidence** \(f \in [0,1]\) is available (from device or proxy), we scale the spread:
   \[
   C_{\mathrm{eff}} = \mathrm{clamp}\bigl( C_1 \cdot (1 - w_f \cdot f);\ C_{\min},\ C_{\max} \bigr),
   \]
   where \(C_1\) is the value after the variance-based adjustment and \(w_f = 0.15\) (`FIXATION_CONFIDENCE_WEIGHT`). So **high fixation confidence** further **reduces** \(C_{\mathrm{eff}}\) (tighter fovea, more aggressive peripheral compression); low or missing confidence leaves \(C_1\) unchanged.

3. The resulting \(C_{\mathrm{eff}}\) is passed to the encoder and used in the Gaussian QP-offset map (see [VIDEO_ENCODING_QP.md](VIDEO_ENCODING_QP.md)).

### 3.3 Data flow

- **Client:** Optionally sends `fixation_confidence` in the face/tracking data (e.g. `FaceData.fixation_confidence`). If the runtime does not provide it, the client omits it (e.g. `None`).
- **Server:** On each tracking update, the server calls `BitrateManager::set_device_fixation_confidence(face_data.fixation_confidence)`. When computing encoder parameters, `get_fixation_confidence()` returns device confidence if set, otherwise the variance-based proxy. That value is passed into `compute_c_effective` and also written into `FfiEyeNexusEncoderParams.fixation_confidence` for logging and C++.

---

## 4. References

[1] **Fixation-based self-calibration for eye tracking in VR headsets.**  
    Uses fixation detection (e.g. velocity/dispersion) and clustering of gaze to improve calibration. Supports the use of gaze stability as a proxy for fixation.  
    *arXiv preprint, 2023.*  
    https://arxiv.org/html/2311.00391

[2] **Evaluation of eye tracking signal quality for virtual reality applications: a case study in the Meta Quest Pro.**  
    Discusses spatial accuracy, precision, and factors affecting gaze quality in VR HMDs; relevant for when device-level confidence or quality metrics become available.  
    *arXiv preprint, 2024.*  
    https://arxiv.org/html/2403.07210

[3] **OpenXR eye gaze interaction (XR_EXT_eye_gaze_interaction).**  
    Describes the standard interface for eye gaze in OpenXR; notes that fixation/confidence may be vendor-specific or future extensions.  
    *Khronos Group.*

[4] **Perceptual saccadic suppression starts in the retina.**  
    Shows that sensitivity to brief stimuli is reduced during saccades and that suppression has a retinal component. Supports reducing reliance on fine detail during non-fixation.  
    *Nature Communications 11, 2020.*  
    https://doi.org/10.1038/s41467-020-15890-w

[5] **Visual sensitivity for luminance and chromatic stimuli during the execution of smooth pursuit and saccadic eye movements.**  
    Reports contrast sensitivity changes during saccades and smooth pursuit; low spatial frequency luminance is more suppressed during saccades.  
    *Vision Research, 2017.*  
    https://doi.org/10.1016/j.visres.2017.05.007

[6] **Li et al., “Visual attention guided bit allocation in video compression.”**  
    Introduces attention-based bit allocation and the **EWPSNR** (eye-tracking-weighted PSNR) metric; shows that weighting quality by gaze improves perceived quality and that attention/fixation predicts where quality matters most.  
    *Image and Vision Computing 29(1), 2011, pp. 1–14.*  
    https://doi.org/10.1016/j.imavis.2010.08.002

[7] **Rimac-Drlje et al., “Foveation-based content Adaptive Structural Similarity index” (FA-SSIM).**  
    Foveation-weighted SSIM for perceptual quality; assumes acuity and importance decrease with distance from the fixation point.  
    *18th International Conference on Systems, Signals and Image Processing (IWSSIP), 2011.*

[8] **Strasburger et al., “Peripheral vision and pattern recognition: A review.”**  
    Reviews resolution and crowding in the periphery; supports that peripheral detail can be compressed more than foveal detail.  
    *Journal of Vision 11(5), 2011.*  
    https://jov.arvojournals.org/article.aspx?articleid=2191906

