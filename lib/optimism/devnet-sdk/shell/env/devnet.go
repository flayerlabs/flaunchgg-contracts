package env

import (
	"encoding/json"
	"fmt"
	"math/big"
	"net/url"
	"strings"

	"github.com/ethereum-optimism/optimism/devnet-sdk/descriptors"
	"github.com/ethereum/go-ethereum/params"
)

type DevnetEnv struct {
	Config descriptors.DevnetEnvironment
	Name   string
	URL    string
}

// DataFetcher is a function type for fetching data from a URL
type DataFetcher func(*url.URL) (string, []byte, error)

// schemeToFetcher maps URL schemes to their respective data fetcher functions
var schemeToFetcher = map[string]DataFetcher{
	"":         fetchFileData,
	"file":     fetchFileData,
	"kt":       fetchKurtosisData,
	"ktnative": fetchKurtosisNativeData,
}

// fetchDevnetData retrieves data from a URL based on its scheme
func fetchDevnetData(devnetURL string) (string, []byte, error) {
	parsedURL, err := url.Parse(devnetURL)
	if err != nil {
		return "", nil, fmt.Errorf("error parsing URL: %w", err)
	}

	scheme := strings.ToLower(parsedURL.Scheme)
	fetcher, ok := schemeToFetcher[scheme]
	if !ok {
		return "", nil, fmt.Errorf("unsupported URL scheme: %s", scheme)
	}

	return fetcher(parsedURL)
}

func LoadDevnetFromURL(devnetURL string) (*DevnetEnv, error) {
	name, data, err := fetchDevnetData(devnetURL)
	if err != nil {
		return nil, fmt.Errorf("error fetching devnet data: %w", err)
	}

	var config descriptors.DevnetEnvironment
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("error parsing JSON: %w", err)
	}

	config, err = fixupDevnetConfig(config)
	if err != nil {
		return nil, fmt.Errorf("error fixing up devnet config: %w", err)
	}

	return &DevnetEnv{
		Config: config,
		Name:   name,
		URL:    devnetURL,
	}, nil
}

func (d *DevnetEnv) GetChain(chainName string) (*ChainConfig, error) {
	var chain *descriptors.Chain
	if d.Config.L1.Name == chainName {
		chain = d.Config.L1
	} else {
		for _, l2Chain := range d.Config.L2 {
			if l2Chain.Name == chainName {
				chain = &l2Chain.Chain
				break
			}
		}
	}

	if chain == nil {
		return nil, fmt.Errorf("chain '%s' not found in devnet config", chainName)
	}

	return &ChainConfig{
		chain:     chain,
		devnetURL: d.URL,
		name:      chainName,
	}, nil
}

func fixupDevnetConfig(config descriptors.DevnetEnvironment) (descriptors.DevnetEnvironment, error) {
	// we should really get this from the kurtosis output, but the data doesn't exist yet, so craft a minimal one.
	if config.L1.Config == nil {
		l1ID := new(big.Int)
		l1ID, ok := l1ID.SetString(config.L1.ID, 10)
		if !ok {
			return config, fmt.Errorf("invalid L1 ID: %s", config.L1.ID)
		}
		config.L1.Config = &params.ChainConfig{
			ChainID: l1ID,
		}
	}
	return config, nil
}
