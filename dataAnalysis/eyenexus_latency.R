library(tidyverse)

setwd("/Users/rohan/Desktop/cs244/eyenexus-extended/dataAnalysis/")

# Load both datasets
stats_baseline <- read.csv("statistics_mtp.csv") |>
  mutate(time_s = (target_ts_nanos - min(target_ts_nanos)) / 1e9) |>
  filter(time_s < 3000)

stats_variance <- read.csv("statistics_mtp_variance.csv") |>
  mutate(time_s = (target_ts_nanos - min(target_ts_nanos)) / 1e9)

stats_variance_2 <- read.csv("statistics_mtp_variance_2.csv") |>
  mutate(time_s = (target_ts_nanos - min(target_ts_nanos)) / 1e9)

# stats_baseline_2 <- read.csv("statistics_mtp_baseline.csv") |>
#  mutate(time_s = (target_ts_nanos - min(target_ts_nanos)) / 1e9)

# stats_variance_more <- read.csv("statistics_mtp_variance_more.csv") |>
#   mutate(time_s = (target_ts_nanos - min(target_ts_nanos)) / 1e9) |>
#   filter(time_s > 4000) |>
#   mutate(time_s = (target_ts_nanos - min(target_ts_nanos)) / 1e9)

# stats_variance_minecraft <- read.csv("statistics_mtp_minecraft.csv") |>
#   mutate(time_s = (target_ts_nanos - min(target_ts_nanos)) / 1e9)
  
datasets <- lst(
  EyeNexus = stats_baseline,
  GazeVariance = bind_rows(stats_variance, stats_variance_2),
  # Variance = stats_variance,
  # Variance2 = stats_variance_2,
  # Baseline2 = stats_baseline_2,
  # VarianceMore = stats_variance_more,
  # VarianceMinecraft = stats_variance_minecraft
)

stats_combined <- bind_rows(datasets, .id = "Dataset")

# Helper to compute latency summary
summarise_latency <- function(df, label) {
  df |>
    summarise(
      Rendering = mean(rendering_latency_ms, na.rm = TRUE),
      Encode = mean(encode_latency_ms, na.rm = TRUE),
      Network = mean(network_latency_ms, na.rm = TRUE),
      Decode = mean(decode_latency_ms, na.rm = TRUE),
      `Dec Queue` = mean(decoder_queue_latency_ms, na.rm = TRUE),
      `Vsync Queue` = mean(vsync_queue_latency_ms, na.rm = TRUE)
    ) |>
    pivot_longer(cols = everything(),
                 names_to = "Component",
                 values_to = "Latency_ms") |>
    mutate(Dataset = label)
}

latency_long <- map2(datasets, names(datasets), summarise_latency) |>
  list_rbind()

# Factor ordering
latency_long$Component <- factor(
  latency_long$Component,
  levels = rev(c("Rendering", "Encode", "Network", "Decode", "Dec Queue", "Vsync Queue"))
)

# Compute totals per dataset for labels
totals <- latency_long |>
  group_by(Dataset) |>
  summarise(total = sum(Latency_ms))

component_colors <- c(
  Rendering = "blue",
  Encode = "green",
  Network = "red",
  Decode = "purple",
  "Dec Queue" = "maroon",
  "Vsync Queue" = "gray"
)

# latency breakdown bar plot
latency_long |>
  ggplot(aes(x = Dataset, y = Latency_ms, fill = Component)) +
  geom_bar(stat = "identity", width = 0.4) +
  coord_flip() +
  theme_minimal(base_size = 14) +
  labs(title = "EyeNexus Latency Decomposition", y = "Latency (ms)", x = "") +
  scale_fill_manual(values = component_colors) +
  theme(
    axis.ticks = element_blank(),
    axis.text.x = element_text(size = 12),
    axis.text.y = element_text(size = 12),
    panel.grid = element_blank()
  ) +
  geom_text(aes(label = round(Latency_ms, 1)),
            position = position_stack(vjust = 0.5),
            color = "white", size = 5) +
  geom_text(data = totals,
            aes(x = Dataset, y = total + 2, label = paste0("Total: ", round(total, 1), " ms"),
                fill = NULL),
            hjust = 1, size = 5, fontface = "bold")

# MTP latency CDF
stats_combined |>
  ggplot(aes(x = total_MTP_latency_ms, color = Dataset)) +
  stat_ecdf(geom = "step", size = 1) +
  coord_cartesian(xlim = c(55, 140)) +
  scale_x_continuous(breaks = seq(60, 140, by = 20)) +
  scale_y_continuous(breaks = seq(0, 1, by = 0.2)) +
  theme_minimal(base_size = 14) +
  labs(
    title = "CDF of MTP Latency (WiFi)",
    x = "Latency (ms)",
    y = ""
  )

# MTP latency (summed from everything but game and composite latency) CDF
stats_combined |>
  ggplot(aes(x = encode_latency_ms+decode_latency_ms+network_latency_ms+decoder_queue_latency_ms+rendering_latency_ms+vsync_queue_latency_ms, color = Dataset)) +
  stat_ecdf(geom = "step", size = 1) +
  coord_cartesian(xlim = c(55, 140)) +
  scale_x_continuous(breaks = seq(60, 140, by = 20)) +
  scale_y_continuous(breaks = seq(0, 1, by = 0.2)) +
  theme_minimal(base_size = 14) +
  labs(
    title = "CDF of MTP Latency (minus game sim and compositing) (WiFi)",
    x = "Latency (ms)",
    y = ""
  )

# MTP latency PDF
stats_combined |>
  ggplot(aes(x = total_MTP_latency_ms, color = Dataset)) +
  coord_cartesian(xlim = c(55, 140)) +
  geom_density(size = 1) +
  theme_minimal(base_size = 14) +
  labs(
    title = "PDF of MTP Latency (WiFi)",
    x = "Latency (ms)",
    y = "Probability Density"
  )

# dot plot of sending bitrate
stats_combined |>
  ggplot(aes(x = time_s, y = sending_bitrate_mbps, color = Dataset)) +
  geom_point(size = 1) +
  labs(
    title = "EyeNexus sending bitrate over time",
    x = "Time (s)",
    y = "Sending Bitrate (mbps)"
  )

# line plot of sending bitrate
stats_combined |>
  ggplot(aes(x = time_s, y = sending_bitrate_mbps, color = Dataset)) +
  stat_summary_bin(
    fun = mean,
    binwidth = 10,
    geom = "step"
  ) +
  theme_minimal()

# average sending bitrates
stats_combined |>
  group_by(Dataset) |>
  summarize(average_sending_bitrate = mean(sending_bitrate_mbps, na.rm = TRUE)) |>
  ggplot(aes(x=Dataset, y=average_sending_bitrate, fill=Dataset)) +
  geom_col(width=.5) +
  geom_text(aes(label = round(average_sending_bitrate, 2)), vjust = 2, size = 5) +
  theme_minimal(base_size = 14) +
  labs(
    title = "Average Sending Bitrate",
    y = "Bitrate (Mbps)",
    x = ""
  )


# line plot of gaze variance
stats_variance |>
  ggplot(aes(x=time_s, y=gaze_variance_magnitude)) +
  stat_summary_bin(fun=mean, binwidth = 10, geom="step") +
  labs(
    title = "Gaze variance magnitude over time",
    x = "Time (s)",
    y = "Magnitude"
  ) +
  theme_minimal()
