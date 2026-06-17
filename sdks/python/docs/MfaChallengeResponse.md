# MfaChallengeResponse


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**id** | **str** |  | 
**expires_at** | **int** |  | [optional] 

## Example

```python
from grobase.models.mfa_challenge_response import MfaChallengeResponse

# TODO update the JSON string below
json = "{}"
# create an instance of MfaChallengeResponse from a JSON string
mfa_challenge_response_instance = MfaChallengeResponse.from_json(json)
# print the JSON string representation of the object
print(MfaChallengeResponse.to_json())

# convert the object into a dict
mfa_challenge_response_dict = mfa_challenge_response_instance.to_dict()
# create an instance of MfaChallengeResponse from a dict
mfa_challenge_response_from_dict = MfaChallengeResponse.from_dict(mfa_challenge_response_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


