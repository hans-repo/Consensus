import re
import numpy as np
import matplotlib.pyplot as plt
import os
from matplotlib.ticker import FuncFormatter
from datetime import datetime

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
# def parse_latency(filename):
#     tick_count_values = []

#     # Regular expression pattern to match lines with _lastDelivered and capture sentTime and _tickCount
#     pattern = r"_lastDelivered.*?_tickCount = (\d+)"
#     sent_time_pattern = r"proposeTime = (\d+)"

#     with open(filename, "r") as file:
#         for line in file:
#             # Extract _tickCount from the line
#             tick_count_match = re.search(pattern, line)
#             if tick_count_match:
#                 tick_count = int(tick_count_match.group(1))
                
#                 # Find all sentTime values in the line
#                 sent_times = re.findall(sent_time_pattern, line)
#                 for sent_time_str in sent_times:
#                     sent_time = int(sent_time_str)
                    
#                     # Calculate the difference and add to tick_count_values
#                     tick_count_diff = tick_count - sent_time
#                     tick_count_values.append(tick_count_diff)
    
#     return tick_count_values
def parse_time(line):
    try:
        # Regular expression to match the timestamp format
        timestamp_pattern = r'(\w{3} \w{3}  ?\d{1,2} \d{2}:\d{2}:\d{2})'
        match = re.search(timestamp_pattern, line)
        
        if not match:
            return None  # Return None if no timestamp is found in the line

        timestamp_str = match.group(1)
        
        # Parse the timestamp string into a datetime object
        timestamp = datetime.strptime(timestamp_str, '%a %b %d %H:%M:%S')
        

        return timestamp
    except ValueError:
        # This will catch parsing errors if the timestamp format is unexpected
        return None
    except Exception as e:
        # This will catch any other unexpected errors
        print(f"Error processing line: {line}")
        print(f"Error message: {str(e)}")
        return None

def parse_throughput2(filename):
    all_throughput = []
    pattern = r"Delivered commands (\d+)"
    pattern_start = "synchronous delta timers set"
    time_start = datetime.now()
    with open(filename, "r") as file:
        for line in file:
            # Search for the pattern in each line
            time = parse_time(line)
            if re.search(pattern_start, line):
                time_start = time
            match = re.search(pattern, line)
            if match:
                time_elapsed = (time - time_start).total_seconds()
                if time_elapsed == 0:
                    continue
                else:
                    throughput = int(match.group(1))/time_elapsed
                    all_throughput.append(throughput)
    skip_start = int(len(all_throughput) * 1)
    return all_throughput[-skip_start:]

def parse_latency2(filename):
    all_latency = []
    pattern = r"Current mean latency: (\d+)"
    with open(filename, "r") as file:
        for line in file:
            # Search for the pattern in each line
            match = re.search(pattern, line)
            if match:
                latency = float(match.group(1))
                if latency > 1:
                    all_latency.append(latency*0.1)
    skip_start = int(len(all_latency) * 1)
    return all_latency[-skip_start:]

# def parse_throughput(filename):
#     ratios = []

#     # Regular expression pattern to match _deliveredCount and _tickCount
#     pattern = r"_deliveredCount = (\d+).*?_tickCount = (\d+)"

#     with open(filename, "r") as file:
#         for line in file:
#             # Search for the pattern in each line
#             match = re.search(pattern, line)
#             if match:
#                 delivered_count = int(match.group(1))
#                 tick_count = int(match.group(2))
                
#                 # Calculate the ratio and save it in ratios
#                 if tick_count != 0:
#                     ratio = delivered_count *1e2/ tick_count
#                     ratios.append(ratio)
    
#     return ratios

pathToResults = "hotstuff/10experiments/"
# pathToResults = ""

latencyResults = []
throughputResults = []
i = 0



while True:
    filename = pathToResults + f"output_{i}.log"
    if not os.path.exists(filename):
        break
    i += 1
    tick_count_values = parse_latency2(filename)
    average, mean, standard_deviation = calculate_stats(tick_count_values)
    latencyResults.append((average, mean, standard_deviation))

    tick_count_values2 = parse_throughput2(filename)
    tick_count_values2 = list(filter(lambda num: num != 0, tick_count_values2))

    average2, mean2, standard_deviation2 = calculate_stats(tick_count_values2)
    throughputResults.append((average2, mean2, standard_deviation2))
    

fig, ax = plt.subplots()
avgThroughputs = [r[1] for r in throughputResults]
avgLatencies = [r[1] for r in latencyResults]
stdLatencies = [r[2] for r in latencyResults]
# plt.errorbar(avgThroughputs, avgLatencies , yerr=stdLatencies, fmt='r--o', capsize=5, capthick=1, ecolor='red')
# plt.xlabel('Average Throughput')
plt.ylabel('Average Latency (s)')
# plt.title('Average Throughput vs Average Latency with Standard Deviation')


nodesIncrements = 5
nrExperiments = 4
nodes = list(range(i))
nodes= [5+nodesIncrements*x for x in nodes]
# plt.plot(nodes[:14], avgThroughputs[:14], marker='+',label="Malkhi et al.")
plt.plot(nodes, avgLatencies, marker='+',color = "purple", label="Hotstuff")
plt.xlabel('Number of nodes')
# plt.ylabel('Average throughput (tps)')


# batchSizeIncrements = 50
# nrExperiments = i
# batchSizes = list(range(i))
# batchSizes= [batchSizeIncrements*x for x in batchSizes]
# plt.plot(batchSizes, avgThroughputs)
# plt.xlabel('batch size')
# plt.ylabel('Average throughput (tps)')
# plt.title('average throughput with increasing batch size')

def k_formatter(x, pos):
    return f'{int(x / (1))}'
# Set the formatter for the x-axis
ax.xaxis.set_major_formatter(FuncFormatter(k_formatter))


pathToResults2 ="results/4experiments/"
# pathToResults2 = ""
latencyResults2 = []
throughputResults2 = []
i = 0

while True:
    filename = pathToResults2 + f"output_{i}.log"
    if not os.path.exists(filename):
        break
    i += 1
    tick_count_values2 = parse_latency2(filename)
    average, mean, standard_deviation = calculate_stats(tick_count_values2)
    latencyResults2.append((average, mean, standard_deviation))

    tick_count_values3 = parse_throughput2(filename)
    tick_count_values3 = list(filter(lambda num: num != 0, tick_count_values3))

    average2, mean2, standard_deviation2 = calculate_stats(tick_count_values3)
    throughputResults2.append((average2, mean2, standard_deviation2))

avgThroughputs2 = [r[1] for r in throughputResults2]
avgLatencies2 = [r[1] for r in latencyResults2]
stdLatencies2 = [r[2] for r in latencyResults2]

# plt.plot(nodes[:14], avgThroughputs2[:14],  marker='+', color='orange', label="Dynamic DAG")
plt.plot(nodes, avgLatencies2,  marker='+', color='cyan', label="GCP")
plt.ylim(0, 1)
# plt.yscale('log')

plt.legend()
plt.grid(True)
plt.show()

