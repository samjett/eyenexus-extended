//! Gaze history and variance for EyeNexus gaze-contingent rate control.
//!
//! Maintains a sliding window of gaze points (in screen space) and computes
//! variance over the window. Used to adapt fovea size and periphery compression
//! (high variance → larger effective fovea; low variance → tighter fovea).
//!
//! This crate has no native dependencies so unit tests can run without
//! OpenVR or encoder DLLs.

use std::collections::VecDeque;

/// Default number of gaze samples to keep (e.g. ~1–2 s at 72–90 Hz).
pub const DEFAULT_GAZE_HISTORY_SIZE: usize = 90;

/// Sliding window of gaze points in screen space (x, y) and variance computation.
#[derive(Debug)]
pub struct GazeHistory {
    samples: VecDeque<(f64, f64)>,
    max_len: usize,
}

impl GazeHistory {
    /// Creates a new gaze history with the given maximum number of samples.
    pub fn new(max_len: usize) -> Self {
        Self {
            samples: VecDeque::with_capacity(max_len),
            max_len,
        }
    }

    /// Pushes a new gaze point (x, y) in screen space. Drops the oldest sample if at capacity.
    /// Typically (x, y) is the left-eye gaze position; both eyes can be averaged by the caller.
    pub fn push(&mut self, x: f64, y: f64) {
        if self.max_len == 0 {
            return;
        }
        if self.samples.len() >= self.max_len {
            self.samples.pop_front();
        }
        self.samples.push_back((x, y));
    }

    /// Number of samples currently in the window.
    pub fn len(&self) -> usize {
        self.samples.len()
    }

    /// Returns true if there are no samples.
    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    /// Population variance of x and y over the window.
    /// Returns `(var_x, var_y)` or `None` if there are fewer than 2 samples.
    pub fn variance(&self) -> Option<(f64, f64)> {
        let n = self.samples.len();
        if n < 2 {
            return None;
        }
        let (sum_x, sum_y): (f64, f64) = self
            .samples
            .iter()
            .fold((0.0, 0.0), |(sx, sy), (x, y)| (sx + x, sy + y));
        let mean_x = sum_x / n as f64;
        let mean_y = sum_y / n as f64;
        let (sum_sq_x, sum_sq_y) = self.samples.iter().fold((0.0, 0.0), |(sx, sy), (x, y)| {
            (
                sx + (x - mean_x) * (x - mean_x),
                sy + (y - mean_y) * (y - mean_y),
            )
        });
        let var_x = sum_sq_x / n as f64;
        let var_y = sum_sq_y / n as f64;
        Some((var_x, var_y))
    }

    /// Single scalar variance magnitude (var_x + var_y) for use in C_effective mapping.
    /// Returns `None` if variance is not available.
    pub fn variance_magnitude(&self) -> Option<f64> {
        self.variance().map(|(vx, vy)| vx + vy)
    }

    /// Standard deviation in x and y (sqrt of variance). Returns `None` if fewer than 2 samples.
    pub fn std_dev(&self) -> Option<(f64, f64)> {
        self.variance().map(|(vx, vy)| (vx.sqrt(), vy.sqrt()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gaze_history_empty() {
        let h = GazeHistory::new(10);
        assert!(h.variance().is_none());
        assert!(h.is_empty());
    }

    #[test]
    fn gaze_history_single_sample() {
        let mut h = GazeHistory::new(10);
        h.push(1.0, 2.0);
        assert!(h.variance().is_none());
        assert_eq!(h.len(), 1);
    }

    #[test]
    fn gaze_history_variance() {
        let mut h = GazeHistory::new(10);
        h.push(0.0, 0.0);
        h.push(2.0, 0.0);
        h.push(0.0, 4.0);
        // mean_x = 2/3, mean_y = 4/3 → var_x = 8/9, var_y = 32/9
        let (vx, vy) = h.variance().unwrap();
        assert!((vx - 8.0 / 9.0).abs() < 1e-10);
        assert!((vy - 32.0 / 9.0).abs() < 1e-10);
        assert!(h.variance_magnitude().unwrap() > 0.0);
    }

    #[test]
    fn gaze_history_sliding() {
        let mut h = GazeHistory::new(3);
        h.push(1.0, 1.0);
        h.push(2.0, 2.0);
        h.push(3.0, 3.0);
        assert_eq!(h.len(), 3);
        h.push(4.0, 4.0);
        assert_eq!(h.len(), 3);
        let (vx, vy) = h.variance().unwrap();
        // Samples are (2,2), (3,3), (4,4) — variance 2/3 each
        assert!((vx - 2.0 / 3.0).abs() < 1e-10);
        assert!((vy - 2.0 / 3.0).abs() < 1e-10);
    }
}
