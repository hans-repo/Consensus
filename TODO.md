# TODO

    ## View Change
        - add a "ticks since last message" counter for every peer as a list in ServerState
        - increment them in tickHandler with a +1 applied to the list
        - reset to 0 when receiving a message
        - if the tick counter for the next leader is too high, send a NewView message
        - Add NewView to message types and add it to message handler.
        - copy the structure of receive votes to form quorums of view change.
        - add condition to propose as the next leader: when view change quorum is obtained.