import unittest, hashlib
from portable import validate_seed, compare_peers

class PortableTest(unittest.TestCase):
    def fixture(self):
        return {key+'Sha256': key[0]*64 for key in ['core','disc','bios','card']}
    def metadata(self):
        data=b'seed'
        return dict(schema=1, bytes=4, sha256=hashlib.sha256(data).hexdigest(), pins=self.fixture())
    def test_valid_seed(self):
        validate_seed(self.metadata(), b'seed', self.fixture())
    def test_modified_seed_rejected(self):
        with self.assertRaises(ValueError): validate_seed(self.metadata(), b'bad!', self.fixture())
    def test_different_fixture_rejected(self):
        fixture=self.fixture();fixture['discSha256']='f'*64
        with self.assertRaises(ValueError): validate_seed(self.metadata(), b'seed', fixture)
    def test_truncated_seed_rejected(self):
        with self.assertRaises(ValueError): validate_seed(self.metadata(), b'see', self.fixture())
    def test_missing_schema_rejected(self):
        metadata=self.metadata();del metadata['schema']
        with self.assertRaises(ValueError): validate_seed(metadata,b'seed',self.fixture())
    def peer(self):
        return {'ramMatchesSeed':True,'serialized':{'matches':True},'samples':[
            {'step':0,'ram':'ram','video':'video','audio':'audio','videoFrames':60,'audioFrames':48000,'inputReads':[1,1]}]}
    def test_both_replays_must_match(self):
        left=self.peer();right=self.peer();right['samples'][0]['ram']='different'
        self.assertFalse(compare_peers(left,right)['passed'])
    def test_restored_state_mismatch_cannot_pass(self):
        left=self.peer();right=self.peer();right['serialized']['matches']=False
        self.assertFalse(compare_peers(left,right)['passed'])
    def test_matching_peer_traces(self):
        self.assertTrue(compare_peers(self.peer(),self.peer())['passed'])

if __name__=='__main__':unittest.main()
