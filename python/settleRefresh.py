from helperOracle import send_function
import json


def settleRefreshPost():
    with open("settleRefresh.json", "r") as f:
        args = json.load(f)
    tx_hash = send_function(
        "settleRefreshPost",
        args["_resultVector"],
        args["_teamsched"],
        args["_starts"],
        gas=1500000,
    )
    return tx_hash


if __name__ == "__main__":
    tx_hash = settleRefreshPost()
    print(f"The transaction hash: {tx_hash.hex()}")
