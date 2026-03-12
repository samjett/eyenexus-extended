library(tidyverse)

stats <- read.csv("statistics_mtp.csv") |>
  mutate(time_s = (target_ts_nanos - min(target_ts_nanos)) / 1e9)

# split into diff play sessions?
stats <- stats |>
  filter(time_s < 3000)

stats |>
  View()

stats |>
  colnames()

# plot of C, the foveation controller (determines size of foveal region)
stats |>
  ggplot(aes(x=time_s, y=C)) +
  coord_cartesian(xlim=c(0,1000)) +
  geom_line()


# get means for all latency stats
latency_summary <- stats |>
  summarise(
    Rendering = mean(rendering_latency_ms, na.rm = TRUE),
    Encode = mean(encode_latency_ms, na.rm = TRUE),
    Network = mean(network_latency_ms, na.rm = TRUE),
    Decode = mean(decode_latency_ms, na.rm = TRUE),
    `Dec Queue` = mean(decoder_queue_latency_ms, na.rm = TRUE),
    `Vsync Queue` = mean(vsync_queue_latency_ms, na.rm = TRUE),
    Composite = mean(composite_latency_ms, na.rm = TRUE),
    Game = mean(game_latency_ms, na.rm = TRUE)
  )

stats |>
  summarize(
    total = mean(total_MTP_latency_ms, na.rm = TRUE)
  )
latency_summary |>
  sum()

# Reshape for plotting
latency_long <- latency_summary |>
  pivot_longer(cols = everything(),
               names_to = "Component",
               values_to = "Latency_ms")

# Reverse the factor levels so Rendering is first in the stack
latency_long$Component <- factor(
  latency_long$Component,
  levels = rev(names(latency_summary))
)

# Compute total latency for proportion labels
total_latency <- sum(latency_long$Latency_ms)
latency_long$proportion <- latency_long$Latency_ms / total_latency

component_colors <- c(
  Rendering = "blue",
  Encode = "green",
  Network = "red",
  Decode = "purple",
  "Dec Queue" = "maroon",
  "Vsync Queue" = "gray"
)

# Stacked horizontal bar plot for latency breakdown
ggplot(latency_long, aes(x = 1, y = Latency_ms, fill = Component)) +
  geom_bar(stat = "identity", width = 0.15) +  # slim vertical bar
  coord_flip() +
  theme_minimal(base_size = 14) +
  labs(title = "EyeNexus Latency Decomposition", y = "Latency (ms)", x = "") +
  scale_fill_manual(values = component_colors) +
  theme(
    axis.ticks = element_blank(),
    axis.text.y = element_blank(),
    axis.text.x = element_text(size = 12),
    panel.grid = element_blank()
  ) +
  geom_text(aes(label = round(Latency_ms, 1)),
            position = position_stack(vjust = 0.5),
            color = "white", size = 5) +
  annotate("text",
           x = 1.05,                     # slightly to the right of the bar
           y = total_latency / 2,        # vertically centered
           label = paste0("Total: ", round(total_latency, 1), " ms"),
           size = 5,
           fontface = "bold")

# MTP latency CDF
stats |>
  ggplot(aes(x = total_MTP_latency_ms)) +
  stat_ecdf(geom="step", color="green", size=1) +
  coord_cartesian(xlim=c(55,140)) +
  scale_x_continuous(breaks = seq(60,140, by = 20)) +
  scale_y_continuous(breaks = seq(0, 1, by = 0.2)) +
  theme_minimal(base_size = 14) +
  labs(
    title="CDF of MTP Latency (WiFi)",
    x = "Latency (ms)",
    y = ""
  )

# MTP latency PDF
stats |>
  ggplot(aes(x = total_MTP_latency_ms)) +
  coord_cartesian(xlim=c(55,140)) +
  geom_density(size = 1, color="green") +
  theme_minimal(base_size = 14) +
  labs(
    title="PDF of MTP Latency (WiFi)",
    x = "Latency (ms)",
    y = "Probability Density"
  ) 

# dot plot of sending bitrate
send_mbps |>
  ggplot(aes(x=time_s, y=sending_bitrate_mbps)) +
  geom_point(size = 1, color = "steelblue") +
  #coord_cartesian(xlim=c(0,5000)) +
  labs(
    title="EyeNexus sending bitrate over time",
    x = "Time (s)",
    y = "Sending Bitrate (mbps)"
    )

# line plot of sending bitrate
send_mbps |>
  ggplot(aes(x=time_s, y=sending_bitrate_mbps)) +
  stat_summary_bin(
    fun = mean,
    binwidth=10,
    geom="step"
  ) +
  theme_minimal()
