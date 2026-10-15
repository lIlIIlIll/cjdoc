"""Exercise canonical member TOC targets across language navigation and filtering."""

from __future__ import annotations
import json
import subprocess
import shutil
import unittest
from test_validate_html_site import canonical_search_script


def callback(script, declaration, end):
    return declaration + script.split(declaration, 1)[1].split(end, 1)[0] + '\n};\n'


def toc_source(script):
    return callback(script, '    const tocTargetId = (heading) => {', '\n    };') + callback(
        script, '    const createLink = (heading, className) => {', '\n    };')


@unittest.skipUnless(shutil.which("node"), "Node.js is required for browser-script regression tests")
class CanonicalMemberTocTest(unittest.TestCase):
    def run_source(self, source, harness):
        result = subprocess.run(['node'], input='const SOURCE=' + json.dumps(source) + ';\n' + harness,
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_desktop_mobile_member_links_preserve_language_route_and_reveal_target(self):
        script = canonical_search_script()
        marker = "(() => {\n  const links = [...document.querySelectorAll('[data-language-routes]')];"
        language = marker + script.split(marker, 1)[1]
        reveal = callback(script, '  const revealHashTarget = (scroll = false) => {', '\n  };')
        source = toc_source(script) + '\n' + language + '\n' + reveal
        harness = r'''
const assert=require('node:assert/strict'),vm=require('node:vm');
const element=()=>({attrs:{},dataset:{},setAttribute(k,v){this.attrs[k]=v},getAttribute(k){return this.attrs[k]}});
const group={hidden:true};let scrolled=0;
const member={id:'symbol-member',tagName:'DETAILS',hidden:true,open:false,
 matches:s=>s==='[data-cjdoc-member]',closest:s=>s==='[data-cjdoc-member-group]'?group:null,
 scrollIntoView(){scrolled++}};
const navigation=element();navigation.setAttribute('href','../zh-CN/owner.html');
navigation.dataset.languageRoutes=JSON.stringify({'symbol-member':['../zh-CN/owner.html#symbol-member','complete']});
const document={createElement:element,querySelector:()=>null,querySelectorAll:()=>[navigation],getElementById:id=>id===member.id?member:null,documentElement:{lang:'en'}};
const location={hash:'#symbol-member'};
const summary={id:'symbol-member-summary',dataset:{cjdocTocRole:'member'},querySelector:()=>null,closest:()=>member};
const sourceHeading={id:'api-heading',dataset:{},querySelector:()=>({getAttribute:()=> 'symbols/api.html'}),closest:()=>null};
const ordinary={id:'overview',dataset:{},querySelector:()=>null,closest:()=>null};
const context=vm.createContext({document,location,window:{location,addEventListener(){}},headingLabel:()=> 'Member',
 summary,sourceHeading,ordinary,memberFilter:{value:'no-match'},originFilter:{value:'extension'},
 isChinese:false,memberTargetNotice:'',applyMemberFilter(){},syncTocVisibility(){},syncMemberActions(){},saveMemberState(){},requestAnimationFrame:f=>f()});
vm.runInContext(SOURCE,context);
for(const kind of ['toc-flat-link','toc-mobile-link']) {
 const link=vm.runInContext('createLink(summary,'+JSON.stringify(kind)+')',context);
 assert.equal(link.getAttribute('href'),'#symbol-member');assert.equal(link.dataset.tocTarget,'symbol-member');
}
assert.equal(summary.id,'symbol-member-summary','keep ARIA label id');
assert.equal(vm.runInContext('createLink(ordinary,"toc-flat-link").getAttribute("href")',context),'#overview');
assert.equal(vm.runInContext('createLink(sourceHeading,"toc-flat-link").getAttribute("href")',context),'symbols/api.html');
assert.equal(navigation.href,'../zh-CN/owner.html#symbol-member');assert.equal(navigation.dataset.positionState,'mapped');
vm.runInContext('revealHashTarget(true)',context);
assert.equal(member.open,true);assert.equal(member.hidden,false);assert.equal(group.hidden,false);
assert.equal(context.memberFilter.value,'');assert.equal(context.originFilter.value,'');assert.equal(scrolled,1);
'''
        self.run_source(source, harness)

    def test_observer_and_filter_visibility_use_canonical_member_ids(self):
        script = canonical_search_script()
        active = callback(script, '      const setActive = (targetId) => {', '\n      };')
        start='      const observer = new IntersectionObserver((entries) => {'
        observer=start+script.split(start,1)[1].split('\n    } else if (headings.length)',1)[0]
        visibility=callback(script, '    syncTocVisibility = () => {', '\n    };')
        source=toc_source(script)+'\n'+active+'\n'+observer+'\n'+visibility
        harness=r'''
const assert=require('node:assert/strict'),vm=require('node:vm');
const classList=()=>{const values=new Set();return {add:x=>values.add(x),remove:(...xs)=>xs.forEach(x=>values.delete(x)),contains:x=>values.has(x)}};
const link=id=>({dataset:{tocTarget:id},classList:classList(),item:{hidden:false},closest(){return this.item}});
const first=link('overview'),entry=link('symbol-member'),mobileFirst=link('overview'),mobileEntry=link('symbol-member');
let hidden=false,observerCallback;
const details={id:'symbol-member',closest:s=>s==='[hidden]'&&hidden?{}:null};
const summary={id:'symbol-member-summary',dataset:{cjdocTocRole:'member'},closest:s=>s==='.member-detail'?details:s==='[hidden]'&&hidden?{}:null};
const overview={id:'overview',dataset:{},closest:()=>null};
const links=[first,entry],headings=[overview,summary];
const tocList={querySelectorAll:()=>links,querySelector:()=>links.find(x=>x.classList.contains('is-active'))};
const mobileTocList={querySelectorAll:()=>[mobileFirst,mobileEntry]};
const context=vm.createContext({document:{getElementById:id=>id==='symbol-member'?details:overview},headings,links,
 byId:new Map(links.map(x=>[x.dataset.tocTarget,x])),parentByLink:new Map(),tocList,mobileTocList,
 toc:{hidden:false},mobileToc:{hidden:false},syncTocVisibility:null,updateActiveToc:null,
 IntersectionObserver:class{constructor(f){observerCallback=f}observe(){}}});
vm.runInContext(SOURCE,context);
assert.equal(first.classList.contains('is-active'),true);
observerCallback([{isIntersecting:true,target:summary}]);
assert.equal(entry.classList.contains('is-active'),true);assert.equal(first.classList.contains('is-active'),false);
context.updateActiveToc=id=>vm.runInContext('setActive('+JSON.stringify(id)+')',context);
hidden=true;vm.runInContext('syncTocVisibility()',context);
assert.equal(entry.item.hidden,true);assert.equal(mobileEntry.item.hidden,true);
assert.equal(first.item.hidden,false);assert.equal(mobileFirst.item.hidden,false);
assert.equal(first.classList.contains('is-active'),true);
observerCallback([{isIntersecting:true,target:summary}]);
assert.equal(first.classList.contains('is-active'),true,'hidden member must not steal active state');
hidden=false;vm.runInContext('syncTocVisibility()',context);
assert.equal(entry.item.hidden,false);assert.equal(mobileEntry.item.hidden,false);
'''
        self.run_source(source,harness)

    def test_search_shortcut_closes_mobile_theme_modal_before_focusing_input(self):
        script=canonical_search_script()
        close=callback(script, '  const closeTheme = (restoreFocus = false) => {', '\n  };')
        start='  document.addEventListener("keydown", (event) => {\n    if ((event.ctrlKey || event.metaKey) && event.key.toLocaleLowerCase() === "k") {'
        hotkey=start+script.split(start,1)[1].split('\n  });',1)[0]+'\n  });\n'
        harness=r'''
const assert=require('node:assert/strict'),vm=require('node:vm');
let handler,focused=false,inert=true,searchOpen=false,prevented=false;
const themePopover={hidden:false},themeBackdrop={hidden:false};
const themeToggle={setAttribute(){},focus(){}};
const context=vm.createContext({themePopover,themeBackdrop,themeToggle,
 document:{documentElement:{classList:{remove(){}}},addEventListener(_,f){handler=f}},
 setThemeModal(active){inert=active},closeMenu(){},openMobileSearch(){searchOpen=true},
 input:{focus(){if(!inert)focused=true}},render(){}});
vm.runInContext(SOURCE,context);
for(const key of ['k','K']) {
 themePopover.hidden=false;themeBackdrop.hidden=false;inert=true;focused=false;searchOpen=false;prevented=false;
 handler({key,ctrlKey:false,metaKey:false,preventDefault(){prevented=true}});
 assert.equal(prevented,false,'ordinary K must keep default action');
 assert.equal(themePopover.hidden,false);assert.equal(themeBackdrop.hidden,false);assert.equal(inert,true);
 assert.equal(searchOpen,false);assert.equal(focused,false);
}
for(const modifier of ['ctrlKey','metaKey']) {
 themePopover.hidden=false;themeBackdrop.hidden=false;inert=true;focused=false;searchOpen=false;prevented=false;
 handler({key:'K',ctrlKey:modifier==='ctrlKey',metaKey:modifier==='metaKey',preventDefault(){prevented=true}});
 assert.equal(prevented,true);assert.equal(themePopover.hidden,true,modifier);
 assert.equal(themeBackdrop.hidden,true);assert.equal(inert,false);assert.equal(searchOpen,true);assert.equal(focused,true);
}
'''
        self.run_source(close+'\n'+hotkey,harness)


if __name__ == "__main__":
    unittest.main()
