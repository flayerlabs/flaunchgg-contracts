package stack

import (
	"github.com/ethereum/go-ethereum/params"

	"github.com/ethereum-optimism/optimism/op-service/eth"
)

// Network is an interface to an ethereum chain and its resources, with common properties between L1 and L2.
// For L1 or L2 specifics, see L1Network and L2Network extensions.
// A network hosts configuration resources and tracks participating nodes.
type Network interface {
	Common

	ChainID() eth.ChainID

	ChainConfig() *params.ChainConfig

	Faucet() Faucet

	User(id UserID) User
	Users() []UserID
}

type ExtensibleNetwork interface {
	Network
	AddUser(v User)
}
