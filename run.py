import subprocess

nrExperiments = 10

for i in range(nrExperiments):
    nodes = 10 #number of nodes
    cmdRate = 1 + i*10 #number of commands sent per 10 millisecond tick to each node
    time = 1200 #number of seconds to run experiment

    # Command to run the Haskell program using cabal
    command = ["cabal", "v2-run", "sleepyBlockDAG", "--", "--replicas", str(nodes), "--cmdRate", str(cmdRate), "--time", str(time)]
    
    # Run the command and capture stdout and stderr
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
     # Wait for the specified number of seconds
    # Check if the command was successful
    if result.returncode == 0:
        # Save the output to a file
        ifilename = "output" + str(i) + ".txt"
        with open(ifilename, "w") as file:
            file.write(result.stdout)
            file.write("\n\n=== Standard Error ===\n\n")
            file.write(result.stderr)
        print("Haskell program output saved to 'output.txt'.")
    else:
        print("Error running Haskell program:")
        print(result.stderr)
