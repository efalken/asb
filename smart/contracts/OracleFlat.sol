// File contracts/ConstantsBetting.sol

/**
SPDX-License-Identifier: MIT License
@author Eric G Falkenstein
*/
pragma solidity 0.8.19;

//1e4 is 1 avax in contract
int64 constant MIN_BET = 1e4;
uint64 constant MIN_DEPOSIT = 1e4;
// used to transform gross odds on favorite, team 0,
// to odds on dog, team 1
int64 constant ODDS_FACTOR1 = 1e8;
int64 constant ODDS_FACTOR2 = 450;
// 1 avax = 1e18 while in contract 1 eth = 1e4, this adjusts avax deposits
uint256 constant UNITS_TRANS14 = 1e14;
// adjusts eth sent to oracle number, 5e12 is 5% of 1e14
uint256 constant ORACLE_5PERC = 5e12;
// 30k tokens allocated for rewards each epoch, given 3 decimals
uint256 constant EPOCH_AMOUNT = 3e7;

// File contracts/Token.sol

pragma solidity 0.8.19;

contract Token {
  uint8 public decimals;
  uint256 public totalSupply;
  uint256 public constant MINT_AMT = 1e9;
  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;
  string public name;
  string public symbol;

  event Transfer(address indexed _from, address indexed _to, uint256 _value);
  event Approval(
    address indexed _owner,
    address indexed _spender,
    uint256 _value
  );

  constructor() {
    balanceOf[msg.sender] = MINT_AMT;
    totalSupply = MINT_AMT;
    name = "AvaxSportsBook";
    symbol = "ASB";
    decimals = 3;
  }

  function approve(
    address _spender,
    uint256 _value
  ) external returns (bool success) {
    allowance[msg.sender][_spender] = _value;
    emit Approval(msg.sender, _spender, _value);
    return true;
  }

  function transfer(
    address _recipient,
    uint256 _value
  ) external returns (bool) {
    uint256 senderBalance = balanceOf[msg.sender];
    require(balanceOf[msg.sender] >= _value, "nsf");
    unchecked {
      balanceOf[msg.sender] = senderBalance - _value;
      balanceOf[_recipient] += _value;
    }
    emit Transfer(msg.sender, _recipient, _value);
    return true;
  }

  function transferFrom(
    address _from,
    address _recipient,
    uint256 _value
  ) external returns (bool) {
    uint256 senderBalance = balanceOf[_from];
    require(senderBalance >= _value && allowance[_from][msg.sender] >= _value);
    unchecked {
      balanceOf[_from] = senderBalance - _value;
      allowance[_from][msg.sender] -= _value;
      balanceOf[_recipient] += _value;
    }
    emit Transfer(_from, _recipient, _value);
    return true;
  }

  function increaseAllowance(
    address _spender,
    uint256 _addedValue
  ) public returns (bool) {
    uint256 _value = allowance[msg.sender][_spender];
    _value += _addedValue;
    allowance[msg.sender][_spender] = _value;
    emit Approval(msg.sender, _spender, _value);
    return true;
  }

  function decreaseAllowance(
    address _spender,
    uint256 _subtractedValue
  ) public returns (bool) {
    uint256 _value = allowance[msg.sender][_spender];
    require(_subtractedValue <= _value, "too large");
    _value -= _subtractedValue;
    allowance[msg.sender][_spender] = _value;
    emit Approval(msg.sender, _spender, _value);
    return true;
  }
}

// File contracts/Betting.sol

pragma solidity 0.8.19;

contract Betting {
  // 0 post-settle/pre-init, 1 post-initial slate/pre-odds
  // 2 post-odds/pre-settle
  uint32 public bettingStatus;
  // increments by one each settlement
  uint32 public bettingEpoch;
  // increments each bet
  uint64 public nonce;
  // adjustible factor for controlling concentration risk
  uint64 public concFactor;
  /* decimal odds for favorite, formatted as decimal odds minus one times 1000 */
  uint16[32] public odds;
  // UTC GMT aka Zulu time. In ISO 8601 it is distinguished by the Z suffix
  uint32[32] public startTime;
  // 0 total LPcapital, 1 LPcapitalLocked, 2 bettorLocked
  uint64[3] public margin;
  // LpShares used to calculate LP revenue
  uint64 public liqProvShares;
  /* 0-betLong[favorite], 1-betLong[away], 2-betPayout[favorite], 3-betPayout[underdog]
  These data are bitpacked for efficiency */
  uint256[32] public betData;
  // the oracle contract as exclusive access to several functions
  address payable public oracleAdmin;
  // for paying LP token Rewards
  Token public token;
  // individual bet contracts
  mapping(bytes32 => Subcontract) public betContracts;
  /* this maps the set {epoch, match, team} to its event outcome,
  via betTarget=epoch * 1000 + match * 10 + teamWinner. 
  For example, epoch 21, match 15, and team 0 wins, would be 21150 */
  mapping(uint32 => uint8) public outcomeMap;
  // This keeps track of an LP's data
  mapping(address => LPStruct) public lpStruct;
  /* this struct holds a bettor's balance and unredeemed trades
  If an LP wants to bet, they will have an independent userStruct */
  mapping(address => UserStruct) public userStruct;

  struct Subcontract {
    uint32 epoch;
    uint32 matchNum;
    uint32 pick;
    uint64 betAmount;
    uint64 payoff;
    address bettor;
  }

  struct UserStruct {
    uint32 counter;
    uint64 userBalance;
    mapping(uint => bytes32) trades;
  }

  struct LPStruct {
    uint64 shares;
    uint32 lpEpoch;
  }

  event BetRecord(
    address indexed bettor,
    uint32 indexed epoch,
    uint32 matchNum,
    uint32 pick,
    int64 betAmount,
    int64 payoff,
    bytes32 contractHash
  );

  event Funding(
    address indexed bettor,
    uint32 epoch,
    uint64 avax,
    uint32 action
  );

  event Redemption(
    address indexed bettor,
    uint32 epoch,
    uint64 payoff,
    uint32 betsRedeemed
  );

  event Rewards(address indexed bettor, uint32 epoch, uint256 tokens);

  constructor(address payable _tokenAddress) {
    concFactor = 5;
    bettingEpoch = 1;
    token = Token(_tokenAddress);
  }

  // @dev restricts data submissions to the Oracle contract

  modifier onlyAdmin() {
    require(oracleAdmin == msg.sender);
    _;
  }

  /**  @dev initial deployment sets administrator as the Oracle contract
  * @param  _oracleAddress is the only account that can process several transactions 
  in this contract
  */
  function setOracleAddress(address payable _oracleAddress) external {
    require(oracleAdmin == address(0), "Only once");
    oracleAdmin = _oracleAddress;
  }

  receive() external payable {}

  /** @dev processes a basic bet
   * @param _matchNumber is 0 to 31, representing the match number as presented in the sequence of weekly matches
   * @param _team0or1 denotes the initial favorite (0) and underdog (1) for a given epoch and matchNumber
   * @param _betAmt is the amount bet in 10s of finney  , 0.0001 ether
   */
  function bet(
    uint32 _matchNumber,
    uint32 _team0or1,
    int64 _betAmt
  ) external returns (bytes32) {
    int64 betPayoff = int64(uint64(odds[_matchNumber]));
    require(betPayoff % 10 == 0, "match halted");
    require(bettingStatus == 2, "odds not ready");
    require(userStruct[msg.sender].counter < 16, "betstack full, redeem bets");
    require(
      (_betAmt <= int64(userStruct[msg.sender].userBalance) &&
        _betAmt >= MIN_BET),
      "too big or too small"
    );
    require(uint256(startTime[_matchNumber]) > block.timestamp, "game started");
    uint64[4] memory _betData = decodeNumber(_matchNumber);
    if (_team0or1 == 0) {
      betPayoff = (_betAmt * betPayoff) / 10000;
    } else {
      betPayoff =
        (_betAmt * (ODDS_FACTOR1 / (betPayoff + ODDS_FACTOR2) - ODDS_FACTOR2)) /
        10000;
    }
    int64 currLpBetExposure = int64(_betData[2 + _team0or1]) -
      int64(_betData[1 - _team0or1]);
    require(
      (betPayoff + currLpBetExposure) <= int64(margin[0] / concFactor),
      "betsize over global book limit"
    );
    int64 currLpExposureOpp = int64(_betData[3 - _team0or1]) -
      int64(_betData[_team0or1]);
    int64 marginChange = maxZero(
      betPayoff + currLpBetExposure,
      -_betAmt + currLpExposureOpp
    ) - maxZero(currLpBetExposure, currLpExposureOpp);
    require(
      marginChange < int64(margin[0] - margin[1]),
      "bet amount exceeds free capital"
    );
    userStruct[msg.sender].userBalance -= uint64(_betAmt);
    bytes32 subkID = keccak256(abi.encodePacked(nonce, block.number));
    Subcontract memory order;
    order.bettor = msg.sender;
    order.betAmount = uint64(_betAmt);
    order.payoff = uint64(betPayoff);
    order.pick = _team0or1;
    order.matchNum = _matchNumber;
    order.epoch = bettingEpoch;
    betContracts[subkID] = order;
    margin[2] += uint64(_betAmt);
    margin[1] = uint64(int64(margin[1]) + marginChange);
    _betData[0 + _team0or1] += uint64(_betAmt);
    _betData[2 + _team0or1] += uint64(betPayoff);
    uint256 encoded;
    encoded |= uint256(_betData[0]) << 192;
    encoded |= uint256(_betData[1]) << 128;
    encoded |= uint256(_betData[2]) << 64;
    encoded |= uint256(_betData[3]);
    betData[_matchNumber] = uint256(encoded);
    nonce++;
    userStruct[msg.sender].trades[userStruct[msg.sender].counter] = subkID;
    userStruct[msg.sender].counter++;
    emit BetRecord(
      msg.sender,
      bettingEpoch,
      _matchNumber,
      _team0or1,
      _betAmt,
      ((betPayoff * 95) / 100),
      subkID
    );
    return subkID;
  }

  /// @dev bettor funds account for bets
  function fundBettor() external payable {
    uint64 amt = uint64(msg.value / UNITS_TRANS14);
    require(amt >= MIN_DEPOSIT, "need at least one avax");
    userStruct[msg.sender].userBalance += amt;
    emit Funding(msg.sender, bettingEpoch, amt, 0);
  }

  /// @dev funds LP for supplying capital to take bets
  function fundBook() external payable {
    require(margin[2] == 0, "betting active");
    uint64 netinvestment = uint64(msg.value / UNITS_TRANS14);
    uint64 _shares = 0;
    require(netinvestment >= uint256(MIN_DEPOSIT), "need at least one avax");
    if (margin[0] > 0) {
      _shares = uint64(
        (uint256(netinvestment) * uint256(liqProvShares)) / uint256(margin[0])
      );
    } else {
      _shares = netinvestment;
    }
    margin[0] += uint64(netinvestment);
    lpStruct[msg.sender].lpEpoch = bettingEpoch;
    liqProvShares += _shares;
    lpStruct[msg.sender].shares += _shares;
    emit Funding(msg.sender, bettingEpoch, netinvestment, 1);
  }

  /** @dev bettor withdrawal
   * @param _amt is the bettor amount where 10000 = 1 avax
   */
  function withdrawBettor(uint64 _amt) external {
    require(_amt <= userStruct[msg.sender].userBalance);
    userStruct[msg.sender].userBalance -= _amt;
    uint256 amt256 = uint256(_amt) * UNITS_TRANS14;
    payable(msg.sender).transfer(amt256);
    emit Funding(msg.sender, bettingEpoch, _amt, 2);
  }

  /** @dev processes withdrawal by LPs
   * @param _sharesToSell is the LP's ownership stake withdrawn.
   */
  function withdrawBook(uint64 _sharesToSell) external {
    require(margin[2] == 0, "betting active");
    require(lpStruct[msg.sender].shares >= _sharesToSell, "NSF");
    require(bettingEpoch > lpStruct[msg.sender].lpEpoch, "no wd w/in epoch");
    uint64 avaxWithdraw = uint64(
      (uint256(_sharesToSell) * uint256(margin[0])) / uint256(liqProvShares)
    );
    require(
      avaxWithdraw <= (margin[0] - margin[1]),
      "insufficient free capital"
    );
    liqProvShares -= _sharesToSell;
    lpStruct[msg.sender].shares -= _sharesToSell;
    margin[0] -= avaxWithdraw;
    uint256 avaxWithdraw256 = uint256(avaxWithdraw) * UNITS_TRANS14;
    payable(msg.sender).transfer(avaxWithdraw256);
    emit Funding(msg.sender, bettingEpoch, avaxWithdraw, 3);
  }

  /** @dev redeems users bet stack of unredeemed bets
   */

  function redeem() external {
    uint256 numberBets = userStruct[msg.sender].counter;
    require(numberBets > 0, "no bets");
    uint64 payout = 0;
    for (uint256 i = 0; i < numberBets; i++) {
      bytes32 _subkId = userStruct[msg.sender].trades[i];
      if (betContracts[_subkId].epoch == bettingEpoch) revert("bets active");
      uint32 epochMatch = betContracts[_subkId].epoch *
        1000 +
        betContracts[_subkId].matchNum *
        10 +
        betContracts[_subkId].pick;
      if (outcomeMap[epochMatch] != 0) {
        payout += betContracts[_subkId].betAmount;
        if (outcomeMap[epochMatch] == 2) {
          payout += (betContracts[_subkId].payoff * 95) / 100;
        }
      }
    }
    userStruct[msg.sender].userBalance += payout;
    emit Redemption(
      msg.sender,
      bettingEpoch,
      payout,
      userStruct[msg.sender].counter
    );
    userStruct[msg.sender].counter = 0;
  }

  /** @dev processes initial start times
   * @param _starts are the start times
   */
  function transmitInit(
    uint32[32] calldata _starts
  ) external onlyAdmin returns (bool) {
    startTime = _starts;
    bettingStatus = 1;
    return true;
  }

  /** @dev processes odds
   * @param _odds gross dec odds for favorite (team0)
   */
  function transmitOdds(
    uint16[32] calldata _odds
  ) external onlyAdmin returns (bool) {
    odds = _odds;
    bettingStatus = 2;
    return true;
  }

  /**  @dev assigns results to matches, enabling withdrawal, removes capital for this purpose
   * @param _winner is the epoch's entry of results: 0 for team 0 win, 1 for team 1 win,
   * 2 for tie or no contest
   * @return first arg is success bool, second the new epoch,
   * third the oracle fee in szabos (avax/1e12).
   */
  function settle(
    uint8[32] memory _winner
  ) external onlyAdmin returns (uint32, uint256) {
    uint64 betReturnPot;
    uint64 winningsPot;
    uint32 epochMatch;
    uint32 winningTeam;
    for (uint32 i = 0; i < 32; i++) {
      winningTeam = uint32(_winner[i]);
      uint64[4] memory _betData = decodeNumber(i);
      if ((_betData[0] + _betData[1]) > 0) {
        epochMatch = i * 10 + bettingEpoch * 1000;
        if (winningTeam != 2) {
          betReturnPot += _betData[winningTeam];
          winningsPot += _betData[winningTeam + 2];
          outcomeMap[(epochMatch + winningTeam)] = 2;
        } else {
          betReturnPot += (_betData[0] + _betData[1]);
          outcomeMap[epochMatch] = 1;
          outcomeMap[1 + epochMatch] = 1;
        }
      }
    }
    uint256 oracleDiv = ORACLE_5PERC * uint256(winningsPot);
    margin[0] = margin[0] + margin[2] - betReturnPot - winningsPot;
    margin[1] = 0;
    margin[2] = 0;
    bettingEpoch++;
    bettingStatus = 0;
    delete betData;
    payable(oracleAdmin).transfer(oracleDiv);
    return (bettingEpoch, oracleDiv);
  }

  /** @dev for distributing 60% of tokens to LPs. Once tokens are depleted 
 this is irrelevant. Tokens go to LP's external account address
   */
  function tokenReward() external {
    uint256 tokensLeft = token.balanceOf(address(this));
    require(tokensLeft > 0, "no token rewards left");
    //require(bettingEpoch > 5, "starts in epoch 6!");
    uint256 lpShares = uint256(lpStruct[msg.sender].shares);
    require(lpShares > 0, "only for liq providers");
    require(bettingEpoch > lpStruct[msg.sender].lpEpoch, "one claim per epoch");
    lpStruct[msg.sender].lpEpoch = bettingEpoch;
    uint256 _amt = ((lpShares * EPOCH_AMOUNT) / uint256(liqProvShares));
    if (_amt > tokensLeft) _amt = tokensLeft;
    token.transfer(msg.sender, _amt);
    emit Rewards(msg.sender, bettingEpoch, _amt);
  }

  /** @dev limits the amount of LP capital that can be applied to a single match.
   * @param _concFactor sets the parameter that defines how much diversification is enforced.
   * eg, if 10, then the max position allowed by bettors is LPcapital/_concFactor
   */
  function adjustConcentrationFactor(uint64 _concFactor) external onlyAdmin {
    concFactor = _concFactor;
  }

  /** @dev this allows oracle to prevent new bets on contests that have bad odds
   * @param _match is the reset match
   */
  function pauseMatch(uint256 _match) external onlyAdmin {
    uint16 oddsi = odds[_match] % 10;
    oddsi = (oddsi == 0) ? 1 : 0;
    odds[_match] = (odds[_match] / 10) * 10 + oddsi;
  }

  function showBetData() external view returns (uint256[32] memory _betData) {
    _betData = betData;
  }

  function showOdds() external view returns (uint16[32] memory _odds) {
    _odds = odds;
  }

  function showStartTime()
    external
    view
    returns (uint32[32] memory _startTime)
  {
    _startTime = startTime;
  }

  /**  @dev this makes it easier for the front-end to present unredeemed bets
   * @param _userAddress is the account who is betting
   * @return _betDataUser is array of unredeemed bet bytes32 IDs
   */
  function showUserBetData(
    address _userAddress
  ) external view returns (bytes32[16] memory _betDataUser) {
    uint256 top = uint256(userStruct[_userAddress].counter);
    for (uint256 i = 0; i < top; i++) {
      _betDataUser[i] = userStruct[_userAddress].trades[i];
    }
  }

  /**  @dev this makes it easier for the front-end to present the status of past bets
   * @param _subkID is the contracts bytes32 ID created with bet
   * @return bool is true if the bet generated a win or tie and thus will
   * move money back to the user's balance
   */
  function checkRedeem(bytes32 _subkID) external view returns (bool) {
    uint32 epochMatchWinner = betContracts[_subkID].epoch *
      1000 +
      betContracts[_subkID].matchNum *
      10 +
      betContracts[_subkID].pick;
    bool redeemable = (outcomeMap[epochMatchWinner] > 0);
    return redeemable;
  }

  /**  @dev unpacks uint256 to 4 uint64 to reveal match's bet amounts
   * @param _matchNumber is the match number from 0 to 31
   * 0 is amt bet on team0, 1 amt bet on team1, 2 payoff for team0, 3 payoff for team1
   */
  function decodeNumber(
    uint32 _matchNumber
  ) internal view returns (uint64[4] memory _vec1) {
    uint256 _encoded = betData[_matchNumber];
    _vec1[0] = uint64(_encoded >> 192);
    _vec1[1] = uint64(_encoded >> 128);
    _vec1[2] = uint64(_encoded >> 64);
    _vec1[3] = uint64(_encoded);
  }

  // @dev takes the maximum of two data points or zero
  function maxZero(int64 _a, int64 _b) internal pure returns (int64) {
    int64 _c = (_a >= _b) ? _a : _b;
    if (_c <= 0) _c = 0;
    return _c;
  }
}

// File contracts/ConstantsOracle.sol

pragma solidity 0.8.19;

// hour of day in GMT one can post new data
uint32 constant HOUR_POST = 22;
// posts cannot be processed until after this hour, before above hour
uint32 constant HOUR_PROCESS = 12;
// odds on favorite must be lower than 2.0 in decimal odds
// odds in system are x=(decimalOdds -1)*1000
uint16 constant MAX_DEC_ODDS = 1000;
// odds on favorite must be higher than 1.125, lower odds events excluded
uint16 constant MIN_DEC_ODDS = 125;
// next post must be an initial slate post
uint8 constant STATUS_INIT = 0;
// next post must be an odds post
uint8 constant STATUS_ODDS = 1;
// next post must be an outcomes post  post
uint8 constant STATUS_SETTLE = 2;
// min amount for submitting data, 10% of supply
uint32 constant MIN_SUBMIT = 1e8;
// min deposit of 5% of token supply encourages token holders to join vaults,
uint32 constant MIN_TOKEN_DEPOSIT = 5e7;
//  encourages but does not guarantee independence among oracle accounts
uint32 constant MAX_TOKEN_DEPOSIT = 15e7;
// used to calculate next friday start, 9 PM GMT in seconds
uint32 constant FRIDAY_21_GMT = 1687554000;
// used to calculate next friday start
uint32 constant SECONDS_IN_HOUR = 3600;
uint32 constant SECONDS_IN_DAY = 86400;
uint32 constant SECONDS_TWO_DAYS = 172800;
uint32 constant SECONDS_FOUR_DAYS = 345600;
uint32 constant SECONDS_IN_WEEK = 604800;

// File contracts/Oracle.sol

pragma solidity 0.8.19;

contract Oracle {
  // prevents illogical sequences of data, eg initial slate after initial slate
  uint8 public reviewStatus;
  // makes possible 2 submissions each propNumber
  uint8 public subNumber;
  // incremented by one each settlement
  uint32 public oracleEpoch;
  // each data submission gets a new propNumber
  uint32 public propNumber;
  // 0 yes votes, 1 no votes
  uint32[2] public votes;
  // next Friday 6pm ET. no settlement submission for 2 days after gamestart
  uint32 public gamesStart;
  //   total tokens deposited
  uint64 public totalTokens;
  // sum of avax revenue/totalTokens
  uint64 public tokenRevTracker;
  // start times in GMT in UTC (aka Greenwich or Zulu time)
  // In ISO 8601 it is presented with a Z suffix
  uint32[32] public propStartTimes;
  // keeps track of  who supplied data proposal, accounts cannot submit consecutive proposals
  // results refer to match result; 0 for team 0 win, 1 for team 1 winning,
  // 2 for a tie or no contest
  uint8[32] public propResults;
  // gross decimal odd, eg even odds 957 => 1 + 0.95*957 => 1.909
  uint16[32] public propOdds;
  /** the schedule is a record of "sport:initialFavorite:InitialUnderdog", 
  such as "NFL:Giants:Bears" for us football
   */
  string[32] public matchSchedule;
  address public proposer;
  // track token holders: ownership metric, whether they voted, their basis for the token fees
  mapping(address => AdminStruct) public adminStruct;
  // this allows the contract to send and receive
  Token public token;
  // link to communicate with the betting contract
  Betting public bettingContract;

  struct AdminStruct {
    uint32 basePropNumber;
    uint32 baseEpoch;
    uint32 voteTracker;
    uint32 totalVotes;
    uint32 tokens;
    uint64 initFeePool;
  }

  event DecOddsPosted(uint32 epoch, uint32 propnum, uint16[32] decOdds);

  event Funding(
    uint32 epoch,
    uint32 tokensChange,
    uint256 etherChange,
    address transactor,
    bool withdrawal
  );

  event ParamsPosted(uint32 epoch, uint32 concLimit);

  event PausePosted(uint32 epoch, uint256 pausedMatch);

  event ResultsPosted(uint32 epoch, uint32 propnum, uint8[32] winner);

  event SchedulePosted(uint32 epoch, uint32 propnum, string[32] sched);

  event StartTimesPosted(uint32 epoch, uint32 propnum, uint32[32] starttimes);

  event VoteOutcome(
    uint32 epoch,
    uint32 propnum,
    uint32 voteYes,
    uint32 votefail,
    address dataProposer
  );

  constructor(address payable bettingk, address payable _token) {
    bettingContract = Betting(bettingk);
    token = Token(_token);
    oracleEpoch = 1;
    propNumber = 1;
    reviewStatus = STATUS_INIT;
  }

  receive() external payable {}

  /**  @dev votes on data submissions
   * @param  _vote is true for good/pass, false for bad/reject
   */
  function vote(bool _vote) external {
    require(adminStruct[msg.sender].tokens > 0, "need tokens");
    require(subNumber > 0, "nothing to vote on");
    require(adminStruct[msg.sender].voteTracker != propNumber, "only one vote");
    adminStruct[msg.sender].voteTracker = propNumber;
    if (_vote) {
      votes[0] += adminStruct[msg.sender].tokens;
    } else {
      votes[1] += adminStruct[msg.sender].tokens;
    }
    adminStruct[msg.sender].totalVotes++;
  }

  /**  @dev set of two arrays for initial betting slate
   * @param  _teamsched is 'sport:favorite:underdog' in a text string
   * @param _starts is the UTC start in Zulu time
   */
  function initPost(
    string[32] memory _teamsched,
    uint32[32] memory _starts
  ) external {
    require(reviewStatus == STATUS_INIT && subNumber < 2, "WRONG ORDER");
    uint32 _blocktime = uint32(block.timestamp);
    gamesStart =
      _blocktime -
      ((_blocktime - FRIDAY_21_GMT) % SECONDS_IN_WEEK) +
      SECONDS_IN_WEEK;
    for (uint256 i = 0; i < 32; i++) {
      require(
        _starts[i] >= gamesStart &&
          _starts[i] < (gamesStart + SECONDS_FOUR_DAYS),
        "start time error"
      );
    }
    propStartTimes = _starts;
    matchSchedule = _teamsched;
    post();
    subNumber += 1;
    emit SchedulePosted(oracleEpoch, propNumber, _teamsched);
    emit StartTimesPosted(oracleEpoch, propNumber, _starts);
  }

  /**  @dev sends odds for weekend events
   * @param _decimalOdds odds is the gross decimial odds for the favorite
   * the decimal odds here are peculiar, in that first, the are
   * (decOdds -1)* 1000 They are also 'grossed up' to anticipate the
   * oracle fee of 5% applied to  the winnings. they are multiplied by
   * 10 to allow a mechanism to identify halted matches
   */
  function oddsPost(uint16[32] memory _decimalOdds) external {
    require(reviewStatus == STATUS_ODDS && subNumber < 2, "WRONG ORDER");
    post();
    for (uint256 i = 0; i < 32; i++) {
      require(
        _decimalOdds[i] < MAX_DEC_ODDS && _decimalOdds[i] > MIN_DEC_ODDS,
        "bad odds"
      );
      propOdds[i] = _decimalOdds[i] * 10;
    }
    emit DecOddsPosted(oracleEpoch, propNumber, _decimalOdds);
    subNumber += 1;
  }

  /**  @dev settle that weeks events by sending outcomes of matches
   *  odds previously sent
   * @param _resultVector are 0 for favorite winning, 1 for dog winning
   * 2 for a tie or no contest
   */
  function settlePost(uint8[32] memory _resultVector) external returns (bool) {
    require(reviewStatus == STATUS_SETTLE && subNumber < 2, "wrong sequence");
    require(
      block.timestamp > uint256(gamesStart + SECONDS_TWO_DAYS),
      "only when weekend over"
    );
    post();
    propResults = _resultVector;
    emit ResultsPosted(oracleEpoch, propNumber, _resultVector);
    subNumber += 1;
    return true;
  }

  /**  @dev A single function processes any of the three data submissions
   * if the vote is favorable, the data are sent to the betting contract
   * if the vote rejects, it does not affect the betting contract
   */
  function processVote() external {
    require(
      hourOfDay() < HOUR_POST && hourOfDay() > HOUR_PROCESS,
      "need gmt hr>12"
    );
    require(subNumber > 0, "nothing to send");
    subNumber = 0;
    if (votes[0] > votes[1]) {
      if (reviewStatus == STATUS_INIT) {
        bool success = bettingContract.transmitInit(propStartTimes);
        if (success) {
          reviewStatus = STATUS_ODDS;
        }
      } else if (reviewStatus == STATUS_ODDS) {
        bool success = bettingContract.transmitOdds(propOdds);
        if (success) {
          reviewStatus = STATUS_SETTLE;
        }
      } else {
        (uint32 _oracleEpoch, uint256 ethDividend) = bettingContract.settle(
          propResults
        );
        if (_oracleEpoch > 0) {
          reviewStatus = STATUS_INIT;
          oracleEpoch = _oracleEpoch;
          tokenRevTracker += uint64(ethDividend / uint256(totalTokens));
        }
      }
    }
    emit VoteOutcome(oracleEpoch, propNumber, votes[0], votes[1], proposer);
    propNumber++;
    delete votes;
  }

  /**  @dev this parameter allows the oracle to adjust how much diversification
   * is enforced. For example, with 32 events, and a concentration limite of 10,
   * and 15.0 avax supplied by the LPs, each event can handle up to 3.2 avax on
   * any single match. Its optimal setting will be discovered by experience.
   */
  function adjConcLimit(uint32 _concentrationLim) external returns (bool) {
    require(adminStruct[msg.sender].tokens >= MIN_SUBMIT);
    bettingContract.adjustConcentrationFactor(_concentrationLim);
    emit ParamsPosted(oracleEpoch, _concentrationLim);
    return true;
  }

  /**  @dev this stops new bets on particular events. It may never be used
   * but it does not add any risk, it just stops more exposure
   * @param  _match is the event to either be halted or reactivated
   * if the current state is active it will be halted, and vice versa
   */
  function haltUnhaltMatch(uint256 _match) external {
    require(adminStruct[msg.sender].tokens >= MIN_SUBMIT);
    bettingContract.pauseMatch(_match);
    emit PausePosted(oracleEpoch, _match);
  }

  /**  @dev token deposits for oracle
   * @param  _amt is the token amount deposited
   * it uses the token contract's exclusive transfer function for this
   * contract, and so does not require the standard approval function
   * it distributes accrued avax if there, as it has to reset the metric used
   * to calculate the fees/tokens relevant to this account's new token amount
   */
  function depositTokens(uint32 _amt) external {
    require(
      (_amt + adminStruct[msg.sender].tokens) >= MIN_TOKEN_DEPOSIT &&
        (_amt + adminStruct[msg.sender].tokens) <= MAX_TOKEN_DEPOSIT,
      "accounts restricted to between 50k and 150k"
    );
    bool success = token.transferFrom(msg.sender, address(this), uint256(_amt));
    require(success, "token transfer failed");
    uint256 _ethOutDeposit;
    totalTokens += uint64(_amt);
    if (
      adminStruct[msg.sender].tokens > 0 &&
      oracleEpoch > adminStruct[msg.sender].baseEpoch
    ) {
      _ethOutDeposit = ethClaim();
    }
    adminStruct[msg.sender].initFeePool = tokenRevTracker;
    adminStruct[msg.sender].tokens += _amt;
    adminStruct[msg.sender].baseEpoch = oracleEpoch;
    adminStruct[msg.sender].totalVotes = 0;
    adminStruct[msg.sender].basePropNumber = propNumber;
    payable(msg.sender).transfer(_ethOutDeposit);
    emit Funding(oracleEpoch, _amt, _ethOutDeposit, msg.sender, false);
  }

  /**  @dev token holder withdrawals
   * @param  _amt is the token amount withdrawn
   * it also sends accrued avax, and resets the account
   */
  function withdrawTokens(uint32 _amt) external {
    require(_amt <= adminStruct[msg.sender].tokens, "nsf tokens");
    require(subNumber == 0, "no wd during vote");
    require(
      (adminStruct[msg.sender].tokens - _amt >= MIN_TOKEN_DEPOSIT) ||
        (adminStruct[msg.sender].tokens == _amt),
      "accounts restricted to min 50k"
    );
    require(adminStruct[msg.sender].baseEpoch < oracleEpoch, "too soon");
    totalTokens -= uint64(_amt);
    uint256 _ethOutWd = ethClaim();
    adminStruct[msg.sender].initFeePool = tokenRevTracker;
    adminStruct[msg.sender].tokens -= _amt;
    adminStruct[msg.sender].baseEpoch = oracleEpoch;
    adminStruct[msg.sender].totalVotes = 0;
    adminStruct[msg.sender].basePropNumber = propNumber;
    bool success = token.transfer(msg.sender, uint256(_amt));
    require(success, "token transfer failed");
    payable(msg.sender).transfer(_ethOutWd);
    emit Funding(oracleEpoch, _amt, _ethOutWd, msg.sender, true);
  }

  function showSchedString() external view returns (string[32] memory) {
    return matchSchedule;
  }

  function showPropOdds() external view returns (uint16[32] memory) {
    return propOdds;
  }

  function showPropResults() external view returns (uint8[32] memory) {
    return propResults;
  }

  function showPropStartTimes() external view returns (uint32[32] memory) {
    return propStartTimes;
  }

  /**  @dev internal function applying standard logic to all data posts
   */
  function post() internal {
    require(hourOfDay() == (subNumber + HOUR_POST), "wrong hour");
    require(
      msg.sender != proposer || subNumber == 1,
      "no consecutive acct posting"
    );
    require(adminStruct[msg.sender].tokens > 0);
    uint32 _tokens = adminStruct[msg.sender].tokens;
    votes[0] = _tokens;
    proposer = msg.sender;
    adminStruct[msg.sender].totalVotes++;
    adminStruct[msg.sender].voteTracker = propNumber;
  }

  /**  @dev internal function that calculates and sends the account's accrued
   * avax to reset the account
   */
  function ethClaim() internal returns (uint256 _ethOut) {
    uint256 votePercentx10000 = (uint256(adminStruct[msg.sender].totalVotes) *
      10000) / uint256(propNumber - adminStruct[msg.sender].basePropNumber);
    if (votePercentx10000 > 10000) votePercentx10000 = 10000;
    uint256 ethTot = uint256(adminStruct[msg.sender].tokens) *
      uint256(tokenRevTracker - adminStruct[msg.sender].initFeePool);
    _ethOut = (votePercentx10000 * ethTot) / 10000;
    uint256 ploughBack = ethTot - _ethOut;
    if (totalTokens > 0) {
      tokenRevTracker += uint64(ploughBack / uint256(totalTokens));
    }
  }

  /**  @dev internal function that calculates GMT hour
   * used to restrict timing of data submissions and votes
   */
  function hourOfDay() public view returns (uint256 hour) {
    hour = (block.timestamp % SECONDS_IN_DAY) / SECONDS_IN_HOUR;
  }
}
