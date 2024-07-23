import re
import numpy as np
import matplotlib.pyplot as plt
import os
from matplotlib.ticker import FuncFormatter

def calculate_stats(data):
    # Convert data to numpy array for efficient calculations
    data_np = np.array(data)
    
    # Calculate average (mean)
    average = np.mean(data_np)
    
    # Calculate mean using numpy
    mean = np.mean(data_np)
    
    # Calculate standard deviation using numpy
    standard_deviation = np.std(data_np)
    
    return average, mean, standard_deviation
def parse_latency(filename):
    tick_count_values = []

    # Regular expression pattern to match lines with _lastDelivered and capture sentTime and _tickCount
    pattern = r"_lastDelivered.*?_tickCount = (\d+)"
    sent_time_pattern = r"sentTime = (\d+)"

    with open(filename, "r") as file:
        for line in file:
            # Extract _tickCount from the line
            tick_count_match = re.search(pattern, line)
            if tick_count_match:
                tick_count = int(tick_count_match.group(1))
                
                # Find all sentTime values in the line
                sent_times = re.findall(sent_time_pattern, line)
                for sent_time_str in sent_times:
                    sent_time = int(sent_time_str)
                    
                    # Calculate the difference and add to tick_count_values
                    tick_count_diff = tick_count - sent_time
                    tick_count_values.append(tick_count_diff)
    
    return tick_count_values

def parse_throughput(filename):
    ratios = []

    # Regular expression pattern to match _deliveredCount and _tickCount
    pattern = r"_deliveredCount = (\d+).*?_tickCount = (\d+)"

    with open(filename, "r") as file:
        for line in file:
            # Search for the pattern in each line
            match = re.search(pattern, line)
            if match:
                delivered_count = int(match.group(1))
                tick_count = int(match.group(2))
                
                # Calculate the ratio and save it in ratios
                if tick_count != 0:
                    ratio = delivered_count*1e6 / tick_count
                    ratios.append(ratio)
    
    return ratios

latencyResults = []
throughputResults = []
i = 1

while True:
    filename = f"output{i}.txt"
    if not os.path.exists(filename):
        break

    tick_count_values = parse_latency(filename)
    average, mean, standard_deviation = calculate_stats(tick_count_values)
    latencyResults.append((average, mean, standard_deviation))

    tick_count_values2 = parse_throughput(filename)
    average2, mean2, standard_deviation2 = calculate_stats(tick_count_values2)
    throughputResults.append((average2, mean2/16, standard_deviation2))
    i += 1

fig, ax = plt.subplots()
avgThroughputs = [r[1] for r in throughputResults]
avgLatencies = [r[1] for r in latencyResults]
stdLatencies = [r[2] for r in latencyResults]
plt.errorbar(avgThroughputs, avgLatencies , yerr=stdLatencies, fmt='o', capsize=5, capthick=1, ecolor='red')
plt.xlabel('Average Throughput')
plt.ylabel('Average Latency')
plt.title('Average Throughput vs Average Latency with Standard Deviation')

def k_formatter(x, pos):
    return f'{int(x / 1000)}k'

# Set the formatter for the x-axis
ax.xaxis.set_major_formatter(FuncFormatter(k_formatter))

plt.grid(True)
plt.show()

# # Plotting the data (example plot)
# plt.figure(1)
# plt.hist(tick_count_values, bins=10, alpha=0.75, color='blue', edgecolor='black')
# plt.xlabel('Tick Count Differences')
# plt.ylabel('Frequency')
# plt.title('Histogram of Tick Count Differences')
# plt.grid(True)
# plt.show(block=False)

# # Example usage:
# output_file = "output.txt"
# tick_count_values = parse_latency(output_file)
# print("Tick count differences:", tick_count_values)
# average, mean, standard_deviation = calculate_stats(tick_count_values)

# # Print the results
# print("Average:", average)
# print("Mean:", mean)
# print("Standard Deviation:", standard_deviation)

# # Plotting the data (example plot)
# plt.figure(1)
# plt.hist(tick_count_values, bins=10, alpha=0.75, color='blue', edgecolor='black')
# plt.xlabel('Tick Count Differences')
# plt.ylabel('Frequency')
# plt.title('Histogram of Tick Count Differences')
# plt.grid(True)
# plt.show(block=False)

# tick_count_values = parse_throughput(output_file)
# print("Average throughput", tick_count_values)
# average, mean, standard_deviation = calculate_stats(tick_count_values)

# # Print the results
# print("Average:", average)
# print("Mean:", mean)
# print("Standard Deviation:", standard_deviation)

# # Plotting the data (example plot)
# plt.figure(2)
# plt.hist(tick_count_values, bins=10, alpha=0.75, color='blue', edgecolor='black')
# plt.xlabel('Average throughput')
# plt.ylabel('Frequency')
# plt.title('Histogram of average throughput')
# plt.grid(True)
# plt.show()

