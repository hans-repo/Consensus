from subprocess import Popen, PIPE, STDOUT
import subprocess
import logging
import sys
import threading


nrExperiments = 7
protocolName = "gradedProposalElection"
nodes = 0  # Number of nodes
time = 300  # Number of seconds to run the experiment
batchSize = 10 #62500 for 500KB of transactions sized 8B each, Narwhal's batch size
crashes = 0


for i in range(nrExperiments):
    nodes = nodes + 5
    crashes = nodes // 3
    # batchSize = batchSize + 50
    # Command to run the Haskell program using cabal
    command = [
        "cabal", "v2-run", protocolName, "--",
        "--replicas", str(nodes),
        "--time", str(time),
        "--crashes", str(crashes),
        "--batchSize", str(batchSize)
    ]

    # Setup logger for the current experiment
    # logger = logging.basicConfig(filename=f"output_{i}.log", level=logging.INFO)
    logger = logging.getLogger(f"experiment_{i}")
    logger.setLevel(logging.INFO)


    process = Popen(command, stdout=PIPE, stderr=STDOUT)
    with process.stdout:
        log_file = f"output_{i}.log"
        log_format = "|%(levelname)s| : [%(filename)s]--[%(funcName)s] : %(message)s"
        formatter = logging.Formatter(log_format)

        # create file handler and set the formatter
        file_handler = logging.FileHandler(log_file)
        file_handler.setFormatter(formatter)

        # add handler to the logger
        logger.addHandler(file_handler)
        for line in iter(process.stdout.readline, b''): # b'\n'-separated lines
            logger.info('%r', line)
    exitcode = process.wait() # 0 means success
    if exitcode == 0:
        print(f"processed experiment {i}")