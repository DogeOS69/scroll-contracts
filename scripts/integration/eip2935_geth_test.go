package integration_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"testing"

	"github.com/scroll-tech/go-ethereum/common"
	"github.com/scroll-tech/go-ethereum/consensus/ethash"
	"github.com/scroll-tech/go-ethereum/core"
	"github.com/scroll-tech/go-ethereum/core/rawdb"
	"github.com/scroll-tech/go-ethereum/core/types"
	"github.com/scroll-tech/go-ethereum/core/vm"
	"github.com/scroll-tech/go-ethereum/crypto"
	"github.com/scroll-tech/go-ethereum/params"
	"github.com/scroll-tech/go-ethereum/trie"
)

// Run from the pinned DogeOS geth checkout; see docs/eip-2935.md.
// This exercises geth's real StateProcessor with the generated genesis alloc.
// Ethash's fake engine replaces sealing only; this does not qualify consensus
// support for later DogeOS forks such as Tsuki.
func TestGeneratedGenesisHistory(t *testing.T) {
	data, err := os.ReadFile(os.Getenv("GENESIS_PATH"))
	if err != nil {
		t.Fatal(err)
	}
	// The generator targets Reth JSON. Legacy geth expects these two L1
	// metadata numbers quoted. Adapt only their encoding, preserving alloc.
	var document map[string]json.RawMessage
	if err = json.Unmarshal(data, &document); err != nil {
		t.Fatal(err)
	}
	var config map[string]json.RawMessage
	if err = json.Unmarshal(document["config"], &config); err != nil {
		t.Fatal(err)
	}
	var scroll map[string]json.RawMessage
	if err = json.Unmarshal(config["scroll"], &scroll); err != nil {
		t.Fatal(err)
	}
	var l1 map[string]json.RawMessage
	if err = json.Unmarshal(scroll["l1Config"], &l1); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"l1ChainId", "numL1MessagesPerBlock"} {
		var n uint64
		if err = json.Unmarshal(l1[name], &n); err != nil {
			t.Fatal(err)
		}
		l1[name], _ = json.Marshal(fmt.Sprint(n))
	}
	scroll["l1Config"], _ = json.Marshal(l1)
	config["scroll"], _ = json.Marshal(scroll)
	document["config"], _ = json.Marshal(config)
	data, _ = json.Marshal(document)
	var genesis core.Genesis
	if err = json.Unmarshal(data, &genesis); err != nil {
		t.Fatal(err)
	}
	account := genesis.Alloc[params.HistoryStorageAddress]
	if account.Nonce != 1 || len(account.Storage) != 0 || !bytes.Equal(account.Code, params.HistoryStorageCode) {
		t.Fatal("noncanonical genesis history account")
	}
	db := rawdb.NewMemoryDatabase()
	defer db.Close()
	parent := genesis.MustCommit(db)
	engine := ethash.NewFaker()
	chain, err := core.NewBlockChain(db, nil, genesis.Config, engine, vm.Config{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer chain.Stop()
	statedb, err := chain.State()
	if err != nil {
		t.Fatal(err)
	}
	processor := core.NewStateProcessor(genesis.Config, chain, engine)
	// Public disposable fixture key, funded by the fixture genesis generator.
	key, _ := crypto.HexToECDSA("0000000000000000000000000000000000000000000000000000000000000001")
	// Constructor STATICCALLs history for NUMBER-1, then returns STOP followed
	// by the read hash and BLOCKHASH(NUMBER-1). Both must equal the parent hash.
	probe := common.FromHex("600143035f5260205f60205f730000f90827f1c53a10cb7a02335b1753200029355afa505f516001525f5f53600143034060215260415ff3")
	for number := uint64(1); number <= 2; number++ {
		header := &types.Header{
			ParentHash: parent.Hash(), Number: new(big.Int).SetUint64(number),
			Time: parent.Time() + 1, GasLimit: genesis.GasLimit,
			BaseFee: genesis.BaseFee, Difficulty: big.NewInt(1),
		}
		tx, err := types.SignTx(types.NewContractCreation(statedb.GetNonce(crypto.PubkeyToAddress(key.PublicKey)), common.Big0, 200000, genesis.BaseFee, probe),
			types.MakeSigner(genesis.Config, header.Number, header.Time), key)
		if err != nil {
			t.Fatal(err)
		}
		block := types.NewBlock(header, []*types.Transaction{tx}, nil, nil, trie.NewStackTrie(nil))
		receipts, _, usedGas, err := processor.Process(block, statedb, vm.Config{})
		if err != nil {
			t.Fatal(err)
		}
		if len(receipts) != 1 || receipts[0].Status != types.ReceiptStatusSuccessful {
			t.Fatal("probe failed")
		}
		expected := append([]byte{0}, parent.Hash().Bytes()...)
		expected = append(expected, parent.Hash().Bytes()...)
		if !bytes.Equal(statedb.GetCode(receipts[0].ContractAddress), expected) {
			t.Fatalf("block %d: parent history/BLOCKHASH was not available during the transaction", number)
		}
		if got := statedb.GetState(params.HistoryStorageAddress, common.BigToHash(new(big.Int).SetUint64(number-1))); got != parent.Hash() {
			t.Fatalf("block %d: incorrect parent storage", number)
		}
		if usedGas != receipts[0].GasUsed {
			t.Fatal("system call consumed block gas")
		}
		header.Root = statedb.IntermediateRoot(true)
		header.GasUsed = usedGas
		parent = types.NewBlock(header, []*types.Transaction{tx}, nil, receipts, trie.NewStackTrie(nil))
		rawdb.WriteHeader(db, parent.Header())
		t.Logf("block %d: parent visible during transaction, gas=%d", number, usedGas)
	}
}
